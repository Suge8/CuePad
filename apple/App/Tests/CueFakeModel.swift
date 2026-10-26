#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import CuePad

/// 本进程里的假 OpenAI chat completions 端点（流式）：按最后一条消息照剧本回，用量固定为 `usage` 个输入 token。
/// 剧本里有的只演第一次（`once`）：第一次出错、第一次不回（连接挂着，等大脑被杀）。
nonisolated final class FakeModel: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-model")
    private let usage: Int
    private let played = Mutex<[String: Int]>([:])
    private let errorCount = Mutex(0)
    var errors: Int { errorCount.withLock { $0 } }
    private let failingOnce: [String]
    private let asksOnEnable: Bool
    /// 回过最后一句的工具结果（工具调用之后这一轮就结束）
    private let finishedAfter = Mutex<[String]>([])
    /// 不回的请求的连接：留着，免得释放时断开
    private let hung = Mutex<[NWConnection]>([])

    private enum Reply {
        case delta([String: Any], finish: String)
        case error(String)
        case hang
    }

    init(usage: Int, failingOnce: [String] = [], asksOnEnable: Bool = false) throws {
        self.failingOnce = failingOnce
        self.asksOnEnable = asksOnEnable
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.usage = usage
    }

    func start() async throws -> UInt16 {
        let (ports, port) = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: port.yield(listener.port?.rawValue)
            case .failed, .cancelled: port.yield(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        for await value in ports { if let value { return value } else { break } }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }

    /// 有挂着不回的请求（"请慢慢想"那一轮已经到了模型这里）
    var hanging: Bool { hung.withLock { !$0.isEmpty } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let body = Self.body(buffer) { return self.respond(connection, body) }
            if done || error != nil { return connection.cancel() }
            self.read(connection, buffer)
        }
    }

    private static func body(_ data: Data) -> Data? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    /// 收到的每个请求用的模型与思考强度（没带强度为 nil），先后有序
    private let requested = Mutex<[(model: String, effort: String?)]>([])
    var requests: [(model: String, effort: String?)] { requested.withLock { $0 } }

    private func respond(_ connection: NWConnection, _ body: Data) {
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        requested.withLock { $0.append((request["model"] as? String ?? "", request["reasoning_effort"] as? String)) }
        send(connection, script(request))
    }

    private func send(_ connection: NWConnection, _ reply: Reply) {
        let delta: [String: Any], finish: String
        switch reply {
        case .hang: return hung.withLock { $0.append(connection) }
        case .error(let message):
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "invalid_request_error"]]), as: UTF8.self)
            let out = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json
            return connection.send(content: Data(out.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .delta(let value, let reason): (delta, finish) = (value, reason)
        }
        var out = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        let usage: [String: Any] = ["prompt_tokens": usage, "completion_tokens": 5, "total_tokens": usage + 5]
        for choice in [["index": 0, "delta": delta] as [String: Any], ["index": 0, "delta": [String: Any](), "finish_reason": finish]] {
            var chunk: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "created": 0, "model": "fake-model", "choices": [choice]]
            if choice["finish_reason"] != nil { chunk["usage"] = usage }
            out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        out += "data: [DONE]\n\n"
        connection.send(content: Data(out.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// 剧本：看最后一条消息。工具的结果——建好了任务就开工，否则说"办好了"；你的话与信封——按关键词调工具或回一句。
    /// 已就结果含 `fragment` 的工具调用回了这一轮最后一句。
    func answered(_ fragment: String) -> Bool { answers(fragment) > 0 }
    /// 收到过几次含 `fragment` 的工具结果。
    func answers(_ fragment: String) -> Int { finishedAfter.withLock { $0.count { $0.contains(fragment) } } }

    /// 这一出还没演满 `times` 次：记一次，返回 true。
    private func once(_ key: String, times: Int = 1) -> Bool {
        played.withLock { played in
            guard played[key, default: 0] < times else { return false }
            played[key, default: 0] += 1
            return true
        }
    }

    private func fail() -> Reply {
        errorCount.withLock { $0 += 1 }
        return .error("bad things happened")
    }

    private func script(_ request: [String: Any]) -> Reply {
        let tools = (request["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        func tool(_ suffix: String) -> String { tools.first { $0.hasSuffix(suffix) } ?? suffix }
        func call(_ suffix: String, _ arguments: [String: Any]) -> Reply {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            return .delta(["role": "assistant", "tool_calls": [["index": 0, "id": "call-\(UUID().uuidString.prefix(8))", "type": "function", "function": ["name": tool(suffix), "arguments": json]]]], finish: "tool_calls")
        }
        func say(_ text: String) -> Reply { .delta(["role": "assistant", "content": text], finish: "stop") }
        // Cue 自己醒来、什么都没做的一轮最后的话不写（`CueKeeper.Turn.writesReply`）：要让你看到它醒来看到了什么，就用 tell 对你说
        func tell(_ text: String) -> Reply { call("tell", ["text": text]) }

        let last = (request["messages"] as? [[String: Any]])?.last ?? [:]
        let text: String = switch last["content"] {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
        default: ""
        }
        let sawImage = (last["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" }
        // 问暗号：从这次请求带着的整段上下文里找你说过的暗号，找不到就是忘了
        if text.contains("暗号是什么") {
            let earlier = (request["messages"] as? [[String: Any]] ?? []).dropLast().map { message -> String in
                switch message["content"] {
                case let string as String: string
                case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
                default: ""
                }
            }
            if let code = earlier.lazy.compactMap({ $0.firstMatch(of: /暗号是 (\S+)/)?.1 }).last { return say("记得，暗号是 \(code)") }
            // 开了新会话：前面的话不在上下文里，只在这一条输入开头的对话视图里
            if let view = text.firstMatch(of: /<view>[\s\S]*<\/view>/)?.0, let code = view.firstMatch(of: /暗号是 (\S+)/)?.1 { return say("从视图接上：暗号是 \(code)") }
            return say("不记得暗号")
        }
        if last["role"] as? String == "tool" {
            if text.contains("建好了"), let id = text.firstMatch(of: /（([0-9a-f]{8})）/)?.1 {
                return call("task", ["action": "start", "task": String(id), "model": "fake/fake-model", "effort": "high"])
            }
            finishedAfter.withLock { $0.append(text) }
            return say("办好了")
        }
        if let answer = text.firstMatch(of: /他回答了「.*」：([^（\n]+)/)?.1 { return say("知道了：\(answer)") }
        if text.contains("请把这张图转给登录页"), let image = text.firstMatch(of: /!\[\]\(cuepad:\/\/img\/[0-9a-f]+\)/)?.0 {
            return call("task", ["action": "say", "task": "修好登录页 转图", "text": "看这张\n\(image)"])
        }
        if sawImage { return say("看到图了") }
        if text.contains("请对登录页说继续") { return call("task", ["action": "say", "task": "修好登录页 说不出去", "text": "继续"]) }
        if let path = text.firstMatch(of: /请读一下关卡 (\S+)/)?.1 { return call("read", ["path": String(path)]) }
        if text.contains("请建个任务并开工") { return call("task", ["action": "add", "title": "修好登录页", "project": "演示", "body": "把登录页修好"]) }
        if text.contains("请问我一个问题") { return call("tell", ["text": "要推送吗？", "ask": "push", "doing": "推送登录页的修复"]) }
        if last["role"] as? String == "user", let key = failingOnce.first(where: text.contains), once("fail:" + key) { return fail() }
        if text.contains("请慢慢想"), once("hang") { return .hang }
        // 后台整理记忆的大脑：输入以待合并的块开头，合第一块
        if let block = text.firstMatch(of: /^#(\d+)-(\d+)\n/) {
            return call("merge", ["lo": Int(block.1)!, "hi": Int(block.2)!, "text": "合起来的偏好"])
        }
        if text.contains("三步并行"), let board = text.firstMatch(of: /在做 \d+ 件：\n((?:[ -][^\n]*\n)+)/)?.1 {
            return text.contains("醒来：会话有动静") ? tell("看板：\n" + board) : say("看板：\n" + board)
        }
        if text.contains("醒来：会话有动静"), let failed = text.firstMatch(of: /\n- (\[(?:出错|发送失败)[^\]]*\] [^\n]*)/)?.1 {
            return tell("看到了：\(failed)")
        }
        if text.contains("醒来：会话有动静"), text.contains("半路断开"), once("midway") {
            return call("task", ["action": "say", "task": "修好登录页 半路断开", "text": "继续"])
        }
        if text.contains("醒来：会话有动静"), text.contains("要作答") { return tell("去作答了") }
        if text.contains("醒来：会话有动静"), text.contains("[等子代理") { return tell("子代理那边停住了") }
        if text.contains("醒来：会话有动静"), text.contains("请收一下") {
            return call("task", ["action": "done", "task": "修好登录页 请收一下", "evidence": ["登录测试全过"]])
        }
        if text.contains("醒来：会话有动静") {
            if text.contains("先出一次错"), once("error") { return fail() }
            if text.contains("先出两次错"), once("error", times: 2) { return fail() }
            if text.contains("只看看") { return say("只是看了看") }
            return tell("登录页那边歇下了")
        }
        if text.contains("醒来：空闲，例行看一眼") { return tell("巡视了一圈") }
        if let fired = text.firstMatch(of: /醒来：定时到点\n- ([^\n]+)/)?.1 { return tell("定时到点：\(fired)") }
        if text.contains("请每周一 9 点清理分支") {
            let at = CueRepeat(.weekly([2]), hour: 9, minute: 0).next(after: .now).formatted(.iso8601)
            return call("memory", ["action": "remind", "text": "清理过期分支", "at": at, "repeat": "FREQ=WEEKLY;BYDAY=MO", "task": "清理过期分支"])
        }
        if text.contains("醒来：刚启用") {
            return asksOnEnable ? call("tell", ["text": "要交给我跟进吗？"]) : say("我看了一眼")
        }
        return say("收到：" + (text.split(separator: "\n").last.map(String.init) ?? ""))
    }
}

extension CueWake {
    var isSessionActivity: Bool { if case .sessionActivity = self { true } else { false } }
}
#endif
