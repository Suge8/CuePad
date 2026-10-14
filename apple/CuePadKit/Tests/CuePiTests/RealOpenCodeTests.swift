#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 本机装的 OpenCode（`brew install opencode`）；没装就跳过。
let realOpenCodeURL = ExecutableLocator.standard.candidates("opencode").first
private let freeModel = PiModelKey(provider: "opencode", id: "big-pickle")

/// 一台隔离的 OpenCode：HOME、XDG 与配置目录都在临时目录里，绝不碰真实的 ~/.config/opencode 与它的库。
/// 后台服务的缺省端口是固定的（0xc0de），会撞上本机真在跑的服务，所以先给它配一个空闲端口。
/// 默认模型是免费的 big-pickle。
final class OpenCodeSandbox {
    let root: URL
    let work: URL
    let environment: [String: String]
    let paths: AgentPaths

    init() async throws {
        let root = try makeTempDirectory()
        let config = root.appending(path: "xc/opencode", directoryHint: .isDirectory)
        self.root = root
        work = root.appending(path: "work", directoryHint: .isDirectory)
        environment = [
            "HOME": root.appending(path: "home").path, "XDG_CONFIG_HOME": root.appending(path: "xc").path,
            "XDG_DATA_HOME": root.appending(path: "xd").path, "XDG_STATE_HOME": root.appending(path: "xs").path,
            "XDG_CACHE_HOME": root.appending(path: "xk").path, "OPENCODE_CONFIG_DIR": config.path, "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "PATH": [realOpenCodeURL!.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
        ]
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: root.appending(path: "s"), environment: [:]), environment: environment)
        for directory in [work, config, root.appending(path: "home")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let settings: [String: Any] = ["model": "\(freeModel.provider)/\(freeModel.id)"]
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "opencode.json"))
        try await run(["service", "set", "port", String(try Self.freePort())])
    }

    /// 跑一条 opencode 命令（在 `directory` 里），要它成功。
    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let opencode = try #require(realOpenCodeURL)
        let result = try #require(
            await ChildProcess.run(opencode, arguments, directory: directory ?? work, environment: environment, timeout: .seconds(180)),
            "opencode \(arguments) 没跑完")
        try #require(result.status == 0, "opencode \(arguments) 失败：\(result.output)")
        return result.output
    }

    struct Service: Decodable { var url: String; var pid: Int32; var password: String }

    var service: Service? {
        (try? Data(contentsOf: paths.openCodeService)).flatMap { try? JSONDecoder().decode(Service.self, from: $0) }
    }

    /// 像终端里的另一个客户端那样直接调服务的接口。
    @discardableResult
    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let service = try #require(service)
        var request = URLRequest(url: URL(string: service.url + path)!)
        request.httpMethod = method
        request.setValue("Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as! HTTPURLResponse).statusCode < 300, "\(method) \(path)：\(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    /// 停掉这台的后台服务（按登记文件里的确切 pid），删掉临时目录。
    func stop() async throws {
        if let pid = service?.pid {
            kill(pid, SIGTERM)
            try await eventually("OpenCode 服务退出") { kill(pid, 0) == -1 && errno == ESRCH }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(fd, $0, length) == 0, getsockname(fd, $0, &length) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// 端到端：真 OpenCode 的后台服务、真模型（免费的 big-pickle，要联网）。CuePad 看得到它的会话、在 CuePad 里跟它说话与作答，
/// 也能在服务没开时自己把它拉起来开新会话、接着已结束的会话。
@MainActor
@Suite(.enabled(if: realOpenCodeURL != nil, "需要 opencode（brew install opencode）"), .serialized, .timeLimit(.minutes(10)))
struct RealOpenCodeTests {
    private func session(_ bridge: PiBridge) -> PiSession? { bridge.sessions.first { $0.agent == .opencode } }

    /// 一台隔离的 OpenCode 加一个空资料库与桥；不论成败，最后停掉接入、按 pid 停掉服务、删掉临时目录。
    private func withOpenCode(_ body: (OpenCodeSandbox, CueStore, PiBridge, OpenCodeRuntime) async throws -> Void) async throws {
        let sandbox = try await OpenCodeSandbox()
        let store = try Fixture().store
        let bridge = PiBridge(socketDirectory: sandbox.paths.pi.socketDirectory)
        let runtime = OpenCodeRuntime(bridge: bridge, paths: sandbox.paths, store: store, hostID: "mac")
        let outcome: Result<Void, any Error>
        do {
            try runtime.start()
            try await body(sandbox, store, bridge, runtime)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        await runtime.stop()()
        try await sandbox.stop()
        try outcome.get()
    }

    private func replies(_ store: CueStore, _ sessionID: String) async throws -> [String] {
        try await store.piMessages(of: sessionID).filter { $0.role == .known(.pi) }.map(\.text)
    }

    /// 终端里（`opencode run`，连着后台服务）说过话的会话出现在 CuePad：实时状态、对话进资料库；CuePad 接着跟它说、改名、换模型与强度、
    /// 回答它要你确认的命令；服务停了会话就下线。
    @Test func aTerminalSessionIsLiveInCuePadAndTakesMessagesAnswersAndSettings() async throws {
        try await withOpenCode { sandbox, store, bridge, _ in
            try await sandbox.run(["run", "Reply with exactly the word PONG and nothing else."])

            try await eventually("终端里的会话上了桥、歇下", timeout: .seconds(60)) { session(bridge)?.state == .settled }
            let live = try #require(session(bridge))
            #expect(live.cwd.resolvingSymlinksInPath() == sandbox.work.resolvingSymlinksInPath())
            #expect(live.model?.key == freeModel && live.context?.window != nil)
            #expect(live.commands.contains { $0.name == "review" } && live.commands.contains { $0.name == "compact" })
            try await eventually("对话进了资料库", timeout: .seconds(60)) {
                try await replies(store, live.sessionID).last?.contains("PONG") == true
            }
            #expect(try await store.piSessions().contains { $0.id == live.sessionID && $0.agent == .opencode })

            let delivery = UUID()
            let delivered = try await bridge.send(PiMessage(text: "Reply with exactly the word AGAIN.", deliveryID: delivery.uuidString), to: live.id)
            #expect(delivered == .immediate)
            try await eventually("CuePad 发的那句认得出来，回答也到了", timeout: .seconds(90)) {
                let messages = try await store.piMessages(of: live.sessionID)
                return messages.contains { $0.deliveryID == delivery } && messages.last { $0.role == .known(.pi) }?.text.contains("AGAIN") == true
            }

            try await bridge.configure(name: "改过的名字", in: live.id)
            try await eventually("改名到了") { session(bridge)?.displayName == "改过的名字" }
            let thinker = PiModelKey(provider: "opencode", id: "cat-jam-free")
            try await bridge.configure(model: thinker, thinking: .high, in: live.id)
            try await eventually("模型与强度换了") { session(bridge)?.model?.key == thinker && session(bridge)?.thinking == .known(.high) }
            let stored = try await sandbox.api("GET", "/api/session/\(live.sessionID)")["data"] as? [String: Any]
            let model = stored?["model"] as? [String: Any]
            #expect(model?["id"] as? String == thinker.id && model?["variant"] as? String == "high" && stored?["title"] as? String == "改过的名字")
            await #expect(throws: PiBridgeError.rejected("unknown_model")) {
                try await bridge.configure(model: PiModelKey(provider: "opencode", id: "no-such-model"), in: live.id)
            }
            await #expect(throws: PiBridgeError.rejected("unknown_command")) { try await bridge.command("/no-such-command", in: live.id) }
            try await bridge.configure(model: freeModel, in: live.id)

            // 用户给这个会话定了规矩：跑命令要先问
            try await sandbox.api("PATCH", "/api/session/\(live.sessionID)", ["permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
            let marker = sandbox.work.appending(path: "approved.txt")
            _ = try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: touch approved.txt  Then reply DONE."), to: live.id)
            try await eventually("在等你确认这条命令", timeout: .seconds(90)) { session(bridge)?.question?.isAnswerable == true }
            let question = try #require(session(bridge)?.question)
            #expect(session(bridge)?.state == .waitingForUser && question.text.contains("touch approved.txt"))
            try await bridge.answer(.option(question.options[0]), to: question.promptID!, in: live.id)
            try await eventually("答了之后命令跑了、这一轮做完", timeout: .seconds(90)) {
                FileManager.default.fileExists(atPath: marker.path) && session(bridge)?.state == .settled
            }

            try await bridge.command("/compact", in: live.id)
            try await eventually("压缩上下文留下一行", timeout: .seconds(90)) {
                try await store.piMessages(of: live.sessionID).contains { $0.role == .known(.system) }
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了，会话下线") { session(bridge) == nil }
        }
    }

    /// 服务没开：CuePad 自己拉起后台服务开新会话、带图发话、派子代理、远程作答它的提问；停止一轮、结束会话，再接着这个已结束的会话说。
    @Test func cuePadStartsTheServiceAndHostsSessionsFromOpenToResume() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            #expect(sandbox.service == nil)

            let id = try await runtime.open(in: sandbox.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(bridge.session(id: id))
            #expect(opened.agent == .opencode && opened.hosted && opened.launchToken == "token-1" && sandbox.service != nil)
            let image = pngData(width: 8, height: 8, shade: 0.9)
            _ = try await bridge.send(PiMessage(text: "Reply with exactly the word SEEN.", images: [PiImage(mimeType: "image/png", data: image)]), to: id)
            let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            try await eventually("带图的那句与回答进了对话", timeout: .seconds(90)) {
                let messages = try await store.piMessages(of: opened.sessionID)
                return messages.contains { $0.role == .known(.user) && $0.text.contains("cuepad://img/\(hash)") }
                    && messages.last?.role == .known(.pi)
            }
            #expect(store.files.fileURL(for: hash) != nil)

            _ = try await bridge.send(PiMessage(text: "Use the subagent tool with agent explore and description find-readme, prompt: list the files in the current directory. Wait for its result, then reply DONE."), to: id)
            try await eventually("子代理出现、做完", timeout: .seconds(180)) {
                session(bridge)?.subagents.contains { $0.name == "find-readme" && $0.role == "explore" && $0.phase == .known(.done) } == true
            }
            try await eventually("这一轮做完", timeout: .seconds(180)) { session(bridge)?.state == .settled }

            _ = try await bridge.send(PiMessage(text: "Use the question tool to ask me one question with header Color and question Which color? with options Red and Blue. After I answer, reply with exactly the color I chose."), to: id)
            try await eventually("在等你回答", timeout: .seconds(90)) { session(bridge)?.question?.kind == .known(.select) }
            let question = try #require(session(bridge)?.question)
            #expect(question.options == ["Red", "Blue"])
            try await bridge.answer(.option("Blue"), to: question.promptID!, in: id)
            try await eventually("按你的回答接着做完", timeout: .seconds(90)) {
                let reply = try await replies(store, opened.sessionID).last
                return session(bridge)?.state == .settled && reply?.contains("Blue") == true
            }

            let long = PiMessage(text: "Write the numbers from 1 to 400, one per line, each with a long sentence about it.")
            _ = try await bridge.send(PiMessage(text: "Write the numbers from 1 to 30, one per line, each with a short sentence about it."), to: id)
            try await eventually("在忙", timeout: .seconds(60)) { session(bridge)?.state.isWorking == true }
            let steered = try await bridge.send(PiMessage(text: "Also reply with the word STEERED at the end.", whenBusy: .steer), to: id)
            #expect(steered == .queued(.steer))
            // 插的话在这一轮里送进去、这一轮接着它做完（模型怎么回不在验收里：免费模型不一定照说）
            try await eventually("插的话进了这一轮，这一轮做完", timeout: .seconds(180)) {
                let messages = try await store.piMessages(of: opened.sessionID)
                let said = messages.lastIndex { $0.role == .known(.user) && $0.text.contains("STEERED") }
                return said.map { messages[$0...].contains { $0.role == .known(.pi) } } == true && session(bridge)?.state == .settled
            }

            _ = try await bridge.send(long, to: id)
            try await eventually("又在忙", timeout: .seconds(60)) { session(bridge)?.state.isWorking == true }
            try await bridge.abort(id)
            try await eventually("停下了") { session(bridge)?.state == .settled }

            try await bridge.end(id)
            #expect(bridge.session(id: id) == nil)
            let indexed = try #require(try await store.piSession(opened.sessionID))
            #expect(indexed.agent == .opencode)

            let resumed = try await runtime.resume(indexed)
            #expect(bridge.session(id: resumed)?.sessionID == opened.sessionID)
            let before = try await replies(store, opened.sessionID).count
            _ = try await bridge.send(PiMessage(text: "Reply with exactly the word BACK."), to: resumed)
            try await eventually("接着说的回答到了", timeout: .seconds(90)) { try await replies(store, opened.sessionID).count > before }

            try await sandbox.api("DELETE", "/api/session/\(opened.sessionID)")
            try await eventually("删掉的会话下线、索引也删了") {
                let indexed = try await store.piSession(opened.sessionID)
                return bridge.session(id: resumed) == nil && indexed == nil
            }
        }
    }
}
#endif
