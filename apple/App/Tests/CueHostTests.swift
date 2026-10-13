#if os(macOS)
import CueStore
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import CuePad

/// Cue 在 Mac 上值班，端到端：真实的 Pi 当大脑（RPC），真实的 `cuepad mcp`（App 里的那份）读写同一个隔离库，
/// 模型是本进程里的假 OpenAI 端点（按剧本回，零网络），执行器开的会话由假扩展扮演（`RecordingHost`）。
/// Pi 的配置在临时目录（`PI_CODING_AGENT_DIR`），不碰 ~/.pi 与真实资料库。
nonisolated private let realPi = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized, .timeLimit(.minutes(2)))
struct CueHostTests {
    final class Rig {
        let model: FakeModel
        let notifier = RecordingCueNotifier()
        let app: TestApp
        let folder: URL
        var services: AppServices { app.services }
        var store: CueStore { services.store }

        init(usage: Int = 100) async throws {
            model = try FakeModel(usage: usage)
            let port = try await model.start()
            let timing = CueTiming(
                quiet: .milliseconds(500), quietLimit: .seconds(2), talking: .zero, patrolAfter: .seconds(3600), mergeAfter: .seconds(3600),
                restarts: [.milliseconds(200), .milliseconds(200), .milliseconds(200)], quietHours: [])
            let scan = CueRuntimeScan(available: [CueRuntimeOption(runtime: .pi, executable: realPi)], path: realPi.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
            app = TestApp(cue: CueDependencies(
                scan: { scan }, helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"), notifier: notifier, timing: timing))
            let agent = app.piPaths.agentDirectory
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try Data(#"{"providers":{"fake":{"baseUrl":"http://127.0.0.1:\#(port)/v1","api":"openai-completions","apiKey":"fake","models":[{"id":"fake-model","contextWindow":200000}]}}}"#.utf8)
                .write(to: agent.appending(path: "models.json"))
            try Data(#"{"defaultProvider":"fake","defaultModel":"fake-model"}"#.utf8).write(to: agent.appending(path: "settings.json"))
            folder = app.directory.appending(path: "demo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await app.services.store.createProject(name: "演示", color: "blue")
            try await app.services.store.setDirectory(folder.path, for: project.id)
            app.services.start()
            try await app.services.cue.enable()
            try await message(.note, containing: "我看了一眼")  // 刚启用的第一次醒来
        }

        func stop() async {
            _ = await services.cue.beginStop()()
            services.cancelBackgroundWork()
            model.stop()
        }

        /// 你对 Cue 说一句。
        func say(_ text: String) async throws { try await store.addCueMessage(.you, text: text) }

        /// 等到出现一条 `author` 写的、含 `text` 的消息。
        @discardableResult
        func message(_ author: CueAuthor, containing text: String, timeout: Duration = .seconds(60)) async throws -> CueMessage {
            var found: CueMessage?
            try await eventually("\(author) 说「\(text)」", timeout: timeout) {
                found = try await self.store.cueMessages().last { $0.author == .known(author) && $0.text.contains(text) }
                return found != nil
            }
            return found!
        }

        /// 这个 Rig 的 Cue 的大脑：本测试进程的子进程里，工作目录是这个库的 Cue 工作目录的（别的测试也在起 Pi）。
        var brainPIDs: [pid_t] {
            let work = app.directory.appending(path: "Library/Cue/work").resolvingSymlinksInPath().path
            var pids = [pid_t](repeating: 0, count: 256)
            let count = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            return pids.prefix(max(0, count)).filter { pid in
                guard pid > 0 else { return false }
                var info = proc_vnodepathinfo()
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return false }
                let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return URL(filePath: cwd).resolvingSymlinksInPath().path == work
            }
        }
    }

    /// 你说一句，Cue 的回答落库（写成 Cue 说的）；你的消息记下已交给大脑。Cue 的大脑不是 Agent 会话：不在会话列表、历史与 Pi 的会话目录里。
    @Test func 你说一句_Cue的回答落库() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        #expect(try await rig.store.cueMessages().first { $0.author == .known(.you) }?.deliveredAt != nil)
        #expect(rig.services.pi.sessions.isEmpty)
        #expect(try await rig.store.allPiSessionStates().isEmpty)
        let sessions = rig.app.piPaths.sessionsDirectory
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).isEmpty)
        await rig.stop()
    }

    /// Cue 经工具建任务并开工：执行器在项目文件夹开出会话，按 Cue 指定的模型与思考强度配置后送进草稿。
    /// 会话歇下后，攒过安静窗口 Cue 自己醒来，这一轮的动态写成灰色一行（note）。
    @Test func 建任务开工_会话歇下后Cue醒来写动态() async throws {
        let rig = try await Rig()
        try await rig.say("请建个任务并开工")
        try await rig.message(.cue, containing: "办好了")
        try await eventually("执行器开出会话") { rig.app.host.calls.contains { if case .open(let directory, _) = $0 { directory == rig.folder.path } else { false } } }
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("配置后送进草稿") { session.received.contains("send") }
        let config = try #require(session.commands.map(\.json).first { $0["t"] as? String == "config" })
        #expect((config["model"] as? [String: String]) == ["provider": "fake", "id": "fake-model"])
        #expect(config["thinking"] as? String == "high")
        #expect(session.messages.first?.text == "把登录页修好")
        #expect(session.received.firstIndex(of: "config")! < session.received.firstIndex(of: "send")!)

        // 认领：真实扩展在 hello 里带开会话的标识，假扩展不带，这里直接把叶子绑上它
        let task = try #require(try await rig.store.cueBoard().first?.task)
        try await rig.store.linkCard(task.id, toSession: session.sessionID)
        session.setState(["kind": "thinking"])
        session.setState(["kind": "idle"])
        try await rig.message(.note, containing: "登录页那边歇下了")
        await rig.stop()
    }

    /// Cue 带选项问你；你回答后 Cue 被唤醒，回答写成 Cue 说的。"等你"推了通知。
    @Test func 等你被回答_Cue被唤醒() async throws {
        let rig = try await Rig()
        try await rig.say("请问我一个问题")
        let question = try await rig.message(.cue, containing: "先做哪个？")
        #expect(question.choices == ["A", "B"])
        try await eventually("推了通知") { rig.notifier.posted.map(\.body) == ["先做哪个？"] }
        try await rig.message(.cue, containing: "办好了")
        try await rig.store.answerCueMessage(question.id, answer: "B")
        try await rig.message(.cue, containing: "知道了：B")
        await rig.stop()
    }

    /// 上下文到了换新线（刚启用那一轮就用到了）：下一次醒来提示先写交接；交接写好、这一轮结束后换新班次，第一轮带着交接醒来。
    @Test func 写交接后新班次接上() async throws {
        let rig = try await Rig(usage: 70_000)
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("第一句")
        try await rig.message(.handoff, containing: "交接：在跟登录页")
        try await rig.message(.note, containing: "接上了：交接：在跟登录页")
        #expect(rig.brainPIDs.count == 1 && rig.brainPIDs.first != first)
        await rig.stop()
    }

    /// 大脑进程被杀：自动重起新班次，接着回答你。
    @Test func 大脑被杀后自动重起() async throws {
        let rig = try await Rig()
        let first = try #require(rig.brainPIDs.first)
        kill(first, SIGKILL)
        try await eventually("重起了大脑") { rig.brainPIDs.contains { $0 != first } && rig.services.cue.state == .idle }
        try await rig.say("还在吗")
        try await rig.message(.cue, containing: "收到：还在吗")
        await rig.stop()
    }
}

/// 本进程里的假 OpenAI chat completions 端点（流式）：按最后一条消息照剧本回，用量固定为 `usage` 个输入 token。
nonisolated final class FakeModel: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-model")
    private let usage: Int

    init(usage: Int) throws {
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

    private func respond(_ connection: NWConnection, _ body: Data) {
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let (delta, finish) = Self.script(request)
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
    private static func script(_ request: [String: Any]) -> (delta: [String: Any], finish: String) {
        let tools = (request["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        func tool(_ suffix: String) -> String { tools.first { $0.hasSuffix(suffix) } ?? suffix }
        func call(_ suffix: String, _ arguments: [String: Any]) -> (delta: [String: Any], finish: String) {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            return (["role": "assistant", "tool_calls": [["index": 0, "id": "call-\(UUID().uuidString.prefix(8))", "type": "function", "function": ["name": tool(suffix), "arguments": json]]]], "tool_calls")
        }
        func say(_ text: String) -> (delta: [String: Any], finish: String) { (["role": "assistant", "content": text], "stop") }

        let last = (request["messages"] as? [[String: Any]])?.last ?? [:]
        let text: String = switch last["content"] {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
        default: ""
        }
        if last["role"] as? String == "tool" {
            if text.contains("建好了"), let id = text.firstMatch(of: /（([0-9a-f]{8})）/)?.1 {
                return call("task", ["action": "start", "task": String(id), "model": "fake/fake-model", "effort": "high"])
            }
            return say("办好了")
        }
        if let answer = text.firstMatch(of: /你回答了「.*」：(.+)/)?.1 { return say("知道了：\(answer)") }
        if text.contains("醒来：换了新上下文"), let handoff = text.firstMatch(of: /(交接：.+)/)?.1 { return say("接上了：\(handoff)") }
        if text.contains("memory renew 写交接") { return call("memory", ["action": "renew", "handoff": "交接：在跟登录页"]) }
        if text.contains("请建个任务并开工") { return call("task", ["action": "add", "title": "修好登录页", "project": "演示", "prompt": "把登录页修好"]) }
        if text.contains("请问我一个问题") { return call("tell", ["text": "先做哪个？", "choices": ["A", "B"]]) }
        if text.contains("醒来：跟进的会话有动静") { return say("登录页那边歇下了") }
        if text.contains("醒来：刚启用") { return say("我看了一眼") }
        return say("收到：" + (text.split(separator: "\n").last.map(String.init) ?? ""))
    }
}
#endif
