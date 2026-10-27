#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Network
import Synchronization
@testable import CuePi

/// 本机的 Grok Build（录制时用）：`CUEPAD_GROK` 指定另一个（如新版本）。
let realGrokURL = ProcessInfo.processInfo.environment["CUEPAD_GROK"].map { URL(filePath: $0) } ?? ExecutableLocator.standard.candidates("grok").first

/// 录制时 Grok 用的模型：环境里给了 `XAI_API_KEY`（只经测试进程的环境给，不写进任何文件）就连真的 xAI，否则连本进程里的假模型（`FakeResponses`）。
/// 假模型的地址与假密钥由录像带起 grok 时加进它的环境（`AgentTape.recordProcess`），不经 CuePad，录像带里也就没有。
enum GrokModel {
    /// 测试进程里共用一个，录制时头一次起 grok 时才开（回放不起：Grok 的输出都在录像带里）；连真模型时为 nil。
    static let fake: FakeResponses? = ProcessInfo.processInfo.environment["XAI_API_KEY"].map(\.isEmpty) == false ? nil : try? FakeResponses()

    /// 录制时给 grok 进程加的环境：假模型的地址与假密钥（本机地址不走代理），不自动更新。
    static var environment: [String: String] {
        ["GROK_DISABLE_AUTOUPDATER": "1"].merging(
            fake.map { ["GROK_XAI_API_BASE_URL": $0.baseURL, "XAI_API_KEY": "fake-xai-key", "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"] } ?? [:]) { $1 }
    }
}

/// 测试用的假 xAI 模型服务：HTTP/1.1 上的 `POST /v1/responses`（SSE，事件同 OpenAI Responses），零网络、结果确定。
/// 回答只看请求里的对话，按最近一句 `<user_query>` 里的话（规则见 `plan`），对得上测试问的那几句；问会话标题、每轮摘要这类旁路请求随便答一句。
/// 停住：一串 echo 调用的第二次请求停住，等测试放行（`release`，先放后停也算）——插话在下一次请求才进对话，测试在插话交出去之后放行；
/// 数数那一句只说开头几个数就停住，直到 Grok 断开（停下这一轮）。都有 30 秒的上限，测试异常退出时不让 Grok 一直等。
final class FakeResponses: Sendable {
    private let listener: NWListener
    let port: UInt16
    private let gate = Mutex<(released: Int, waiting: [CheckedContinuation<Void, Never>])>((0, []))
    private static let ceiling = Duration.seconds(30)

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// 同步等到端口开好（只在录制时头一次起 grok 时，不在主线程上）。连接的处理要在开始监听前给（`NWListener` 的要求），
    /// 那时还没有 self：先进一个流，开好后再接。
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let connections = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connections.continuation.yield($0) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())
        ready.wait()
        port = listener.port?.rawValue ?? 0
        Task { [weak self] in
            for await connection in connections.stream {
                connection.start(queue: .global())
                Task { await self?.serve(connection) }
            }
        }
    }

    /// 放行一次停住。
    func release() {
        let waiter = gate.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.waiting.isEmpty else { return state.waiting.removeFirst() }
            state.released += 1
            return nil
        }
        waiter?.resume()
    }

    private func hold() async {
        await withTaskGroup { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let ready = self.gate.withLock { state in
                        guard state.released == 0 else { state.released -= 1; return true }
                        state.waiting.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
            group.addTask { try? await Task.sleep(for: Self.ceiling) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        var data = Data()
        while true {
            guard let chunk = await Self.receive(connection) else { return }
            data.append(chunk)
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard data.count - end.upperBound >= length else { continue }
            guard head.hasPrefix("POST"), head.contains("/responses"),
                  let body = try? JSONSerialization.jsonObject(with: data[end.upperBound...]) as? [String: Any]
            else {
                await Self.send(connection, "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
                return
            }
            await respond(Self.plan(body), model: body["model"] as? String ?? "grok", input: body["input"], on: connection)
            return
        }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                continuation.resume(returning: error != nil || (done && data == nil) ? nil : data ?? Data())
            }
        }
    }

    @discardableResult
    private static func send(_ connection: NWConnection, _ text: String) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
    }

    // MARK: 回答

    enum Plan {
        case say(String)
        case call(String, [String: Any])
        /// 停住，放行后照它答
        indirect case held(Plan)
        /// 说出这几段就停住，直到对方断开
        case endless([String])
    }

    /// 最近一句你的话决定怎么答（测试问的那几句）；其余回 "ECHO <原话>"。
    static func plan(_ body: [String: Any]) -> Plan {
        let input = body["input"] as? [[String: Any]] ?? []
        let system = (body["instructions"] as? String) ?? input.first { $0["role"] as? String == "system" }.map(text) ?? ""
        if system.hasPrefix("You are tasked with generating the session title") { return .say("Probe session") }
        if system.hasPrefix("Write an ultra-short dashboard") { return .say("Probe summary") }
        let users = input.filter { $0["role"] as? String == "user" }.map(text)
        guard let queryIndex = input.lastIndex(where: { $0["role"] as? String == "user" && text($0).contains("<user_query>") }) else { return .say("ECHO") }
        let query = text(input[queryIndex]).components(separatedBy: "<user_query>").last?.components(separatedBy: "</user_query>").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let after = input[(queryIndex + 1)...]
        let calls = after.filter { $0["type"] as? String == "function_call" }
        let outputs = after.compactMap { $0["type"] as? String == "function_call_output" ? $0["output"] as? String : nil }
        if users.contains(where: { $0.contains("Stop now") }) { return .say("STOPPED") }
        if query.contains("Call the echo tool") {
            if calls.isEmpty { return .call("cuepad__echo", ["text": "x"]) }
            let next: Plan = calls.count < 8 ? .call("cuepad__echo", ["text": outputs.last ?? "x"]) : .say(outputs.last ?? "")
            return calls.count == 1 ? .held(next) : next
        }
        if let codename = system.firstMatch(of: /codename is ([A-Z0-9-]+)/)?.output.1, query.contains("codename") { return .say(String(codename)) }
        if query.contains("color") {
            let seen = input.contains { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "input_image" } == true }
            return .say(seen ? "red" : "I see no image")
        }
        if query.contains("Remember the word") { return .say("OK") }
        if query.contains("What word did I ask you to remember") {
            return .say(users.lazy.compactMap { $0.firstMatch(of: /Remember the word (\w+)/)?.output.1 }.first.map(String.init) ?? "?")
        }
        if query.contains("numbers from 1 to 400") { return .endless(["1\n", "2\n", "3\n"]) }
        if query.contains("hack.txt") {
            return calls.isEmpty ? .call("run_terminal_command", ["command": "echo x > hack.txt", "description": "write the file"]) : .say("I cannot write files here.")
        }
        if let command = query.firstMatch(of: /Run exactly this shell command: (.+)/)?.output.1 {
            return calls.isEmpty ? .call("run_terminal_command", ["command": String(command), "description": "run it"]) : .say("DONE")
        }
        if let word = query.firstMatch(of: /single word ([A-Za-z]+)/)?.output.1 { return .say(String(word)) }
        return .say("ECHO \(query)")
    }

    /// 一条消息的文字：字符串，或内容块里的文字拼起来。
    private static func text(_ item: [String: Any]) -> String {
        if let text = item["content"] as? String { return text }
        return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func respond(_ plan: Plan, model: String, input: Any?, on connection: NWConnection) async {
        if case .held(let next) = plan {
            await hold()
            return await respond(next, model: model, input: input, on: connection)
        }
        guard await Self.send(connection, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n") else { return }
        var sequence = 0
        func event(_ type: String, _ fields: [String: Any]) async -> Bool {
            var object = fields
            object["type"] = type
            object["sequence_number"] = sequence
            sequence += 1
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            return await Self.send(connection, "event: \(type)\ndata: \(json)\n\n")
        }
        let id = "resp_\(UUID().uuidString.prefix(8))"
        let base: [String: Any] = ["id": id, "object": "response", "created_at": Int(Date().timeIntervalSince1970), "model": model, "tools": [], "metadata": [:]]
        guard await event("response.created", ["response": base.merging(["status": "in_progress", "output": []]) { $1 }]) else { return }
        var item: [String: Any]
        switch plan {
        case .call(let name, let arguments):
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            item = ["type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": name, "arguments": json, "status": "completed"]
            guard await event("response.output_item.added", ["output_index": 0, "item": item.merging(["arguments": ""]) { $1 }]),
                  await event("response.function_call_arguments.delta", ["output_index": 0, "item_id": "fc_\(id)", "delta": json]),
                  await event("response.function_call_arguments.done", ["output_index": 0, "item_id": "fc_\(id)", "arguments": json])
            else { return }
        case .say(let text):
            item = await message(id: "msg_\(id)", text: text, event: event)
        case .endless(let parts):
            _ = await event("response.output_item.added", ["output_index": 0, "item": ["type": "message", "id": "msg_\(id)", "role": "assistant", "status": "in_progress", "content": []]])
            for part in parts {
                guard await event("response.output_text.delta", ["output_index": 0, "item_id": "msg_\(id)", "content_index": 0, "delta": part, "logprobs": []]) else { return }
            }
            // 说到一半停住：直到 Grok 断开（停下这一轮）
            _ = await Self.receive(connection)
            return
        case .held:
            return
        }
        guard await event("response.output_item.done", ["output_index": 0, "item": item]) else { return }
        let used = String(describing: input ?? "").utf8.count / 4 + 1
        let usage: [String: Any] = [
            "input_tokens": used, "output_tokens": 7, "total_tokens": used + 7,
            "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0],
        ]
        _ = await event("response.completed", ["response": base.merging(["status": "completed", "output": [item], "usage": usage]) { $1 }])
    }

    private func message(id: String, text: String, event: (String, [String: Any]) async -> Bool) async -> [String: Any] {
        _ = await event("response.output_item.added", ["output_index": 0, "item": ["type": "message", "id": id, "role": "assistant", "status": "in_progress", "content": []]])
        _ = await event("response.content_part.added", ["output_index": 0, "item_id": id, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])
        _ = await event("response.output_text.delta", ["output_index": 0, "item_id": id, "content_index": 0, "delta": text, "logprobs": []])
        _ = await event("response.output_text.done", ["output_index": 0, "item_id": id, "content_index": 0, "text": text, "logprobs": []])
        return ["type": "message", "id": id, "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text, "annotations": []]]]
    }
}
#endif
