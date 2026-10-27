#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Grok Build（`grok agent stdio`，录制时连假模型，见 `GrokModel`），对话来自它的会话记录；
/// 终端里开着的 Grok 会话从它的登记与会话记录只读跟读。
@MainActor
@Suite(RealAgents.taped(.grok), .agentTape(.grok), RealAgents.timeLimit(.minutes(3)), RealAgents.serialWhenRecording(.grok))
struct RealGrokTests {
    /// 开一个新会话、发一句带图的话：会话出现在桥上（后台托管、带着认领标识），做完一轮后歇下、报上下文余量；会话记录里你的话带着这次投送的 id 与图片，
    /// 回答是一条 Grok 消息；换模型、强度与改名生效，不认的模型提示点的是 Grok。结束后下线；再接着这个已结束的会话说，它在后台恢复、接着回答。
    @Test func aHostedSessionTakesAMessageWithAnImageIsConfiguredEndedAndResumed() async throws {
        try await withGrokRig { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(rig.bridge.session(id: id))
            #expect(opened.hosted && opened.agent == .grok && opened.launchToken == "token-1")
            let delivery = UUID()
            let message = PiMessage(text: "What color is this image? Answer with one lowercase word.", images: [PiImage(mimeType: "image/png", data: redPNG)], deliveryID: delivery.uuidString)
            try await rig.bridge.send(message, to: id)
            try await eventually("这一轮做完、报了上下文余量、回答落盘") {
                log.states.contains(.thinking) && rig.bridge.session(id: id).map {
                    $0.state == .settled && $0.context?.window ?? 0 > 0 && rig.replies($0).last?.lowercased().contains("red") == true
                } == true
            }

            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://img/"))

            let other = try #require(session.availableModels.first { $0.key.id != session.model?.key.id })
            try await rig.bridge.configure(model: other.key, thinking: .high, name: "看图", in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            let unknown = await #expect(throws: PiBridgeError.unknownModel(.grok)) {
                try await rig.bridge.configure(model: PiModelKey(provider: AgentKind.grok.rawValue, id: "no-such-model"), in: id)
            }
            #expect(unknown?.localizedDescription == "这台 Mac 上的 Grok Build 里找不到这个模型")

            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(IndexedSession(id: session.sessionID, path: file.path, cwd: rig.work.path, lastActivityAt: .now, agent: .grok))
            #expect(rig.bridge.session(id: resumed)?.hosted == true && rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
            try await rig.bridge.send(PiMessage(text: "Reply with the single word AGAIN."), to: resumed)
            try await eventually("接着回答了") { rig.replies(session).last == "AGAIN" }
        }
    }

    /// 需要你确认的命令：会话停在"等你确认"、带着要跑的命令；在 CuePad 里允许后命令照常跑完，这一轮做完。
    @Test func aPermissionRequestIsAnsweredFromCuePad() async throws {
        try await withGrokRig { rig in
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-2", name: nil, model: nil, thinking: nil)
            let marker = rig.work.appending(path: "marker.txt")

            try await rig.bridge.send(PiMessage(text: "Run exactly this shell command: echo ok > marker.txt"), to: id)
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.contains("echo ok > marker.txt"), "\(question.text)")

            try await rig.bridge.answer(.confirmed(true), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && rig.replies(rig.bridge.session(id: id)!).last == "DONE" }
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// 说了一句正在跑时停下：这一轮就此结束，会话歇下、能接着说。
    @Test func aRunningTurnIsAborted() async throws {
        try await withGrokRig { rig in
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-3", name: nil, model: nil, thinking: nil)
            try await rig.bridge.send(PiMessage(text: "Write the numbers from 1 to 400, one per line."), to: id)
            try await eventually("在说") { rig.bridge.session(id: id)?.state == .thinking && rig.bridge.slots.first { $0.id == id }?.draft != nil }

            try await rig.bridge.abort(id)
            try await eventually("停下歇着") { rig.bridge.session(id: id)?.state == .settled }
            try await rig.bridge.send(PiMessage(text: "Reply with the single word NEXT."), to: id)
            try await eventually("接着回答了") { rig.bridge.session(id: id).map { rig.replies($0).last == "NEXT" } == true }
        }
    }

    /// 终端里开着的会话（登记在 `active_sessions.json`）：范围里的接上桥，只读——能力表里什么都没有，说话被挡下并说明只能在终端里；
    /// 会话记录里一轮开始到结束跟着在跑、歇下；登记注销后下桥。终端的会话记录借托管会话录下的那份。
    @Test func aTerminalSessionIsFollowedReadOnly() async throws {
        try await withGrokRig { rig in
            let hosted = try await rig.runtime.open(in: rig.work, launchToken: "token-4", name: nil, model: nil, thinking: nil)
            try await rig.bridge.send(PiMessage(text: "Reply with the single word FIRST."), to: hosted)
            let session = try #require(rig.bridge.session(id: hosted))
            try await eventually("回答落盘") { rig.replies(session).last == "FIRST" }
            try await rig.bridge.end(hosted)
            try await eventually("托管的下线") { rig.bridge.session(id: hosted) == nil }

            // 记录先停在你说了一句、还没答完（终端里正在跑）
            let file = try #require(session.sessionFile)
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            let asked = try #require(lines.firstIndex { $0.contains("\"user_message_chunk\"") })
            let full = try String(contentsOf: file, encoding: .utf8)
            try (lines[...asked].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            rig.runtime.follow(.sessions([session.sessionID]))
            let entry: [[String: Any]] = [["session_id": session.sessionID, "pid": Int(getpid()), "cwd": rig.work.path]]
            try JSONSerialization.data(withJSONObject: entry).write(to: rig.home.appending(path: "active_sessions.json"))

            try await eventually("接上桥、在跑") { rig.bridge.sessions.first { $0.sessionID == session.sessionID && !$0.hosted }?.state == .thinking }
            let terminal = try #require(rig.bridge.sessions.first { $0.sessionID == session.sessionID })
            #expect(terminal.capabilities == [])
            await #expect(throws: PiBridgeError.self) { try await rig.bridge.send(PiMessage(text: "hi"), to: terminal.id) }

            try full.write(to: file, atomically: true, encoding: .utf8)
            rig.runtime.read(try PiHistory.index(file: file, agent: .grok, from: nil, files: scratchFiles))
            try await eventually("这一轮做完歇下") { rig.bridge.session(id: terminal.id)?.state == .settled }

            try "[]".write(to: rig.home.appending(path: "active_sessions.json"), atomically: true, encoding: .utf8)
            try await eventually("下桥") { rig.bridge.session(id: terminal.id) == nil }
        }
    }
}

/// 一个临时的 Grok 配置目录与工作目录，起的 grok 与家目录都指到这里，不读写真实的 ~/.grok 与资料库。
@MainActor
final class GrokRig {
    let root: URL
    let bridge: PiBridge
    let runtime: GrokRuntime
    var home: URL { root.appending(path: "grok", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

    init() throws {
        root = try makeTempDirectory().resolvingSymlinksInPath()
        for directory in [root.appending(path: "grok"), root.appending(path: "work"), root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sockets = root.appending(path: "s", directoryHint: .isDirectory)
        let isolated = ["CUEPAD_", "GROK_", "XDG_", "CLAUDE_", "PI_"]
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in !isolated.contains { key.hasPrefix($0) } }.merging([
            "HOME": root.appending(path: "user").path, "GROK_HOME": root.appending(path: "grok").path, "CUEPAD_PI_SOCKET_DIR": sockets.path,
            "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path,
        ]) { $1 }
        let paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        bridge = PiBridge(socketDirectory: sockets)
        runtime = GrokRuntime(
            bridge: bridge, paths: paths, files: scratchFiles, grok: { AgentTape.executable("grok") }, locate: { AgentTape.locator("grok") }, timing: noDeadline)
        // 会话目录里 CuePad 只读会话记录（`updates.jsonl`），别的（工具定义、检索库）不录
        AgentTape.current?.watch(root.appending(path: "grok/sessions"), named: "updates.jsonl")
        AgentTape.current?.watch(root.appending(path: "work"))
        try bridge.start()
        try runtime.start()
    }

    func stop() async {
        await runtime.stop()()
        bridge.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func transcript(_ session: PiSession) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(session.sessionFile), agent: .grok, from: nil, files: scratchFiles)
    }

    func replies(_ session: PiSession) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

@MainActor
func withGrokRig(_ body: (GrokRig) async throws -> Void) async throws {
    let rig = try GrokRig()
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}
#endif
