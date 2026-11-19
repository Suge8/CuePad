#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CueBridge

/// CuePad 托管的会话里，Agent 用自己的工具跑 `cuepad live snapshot`：会话记着承载它的进程（`piProcesses`），
/// 只有那个进程的后代能以这个会话操作活预览（`LiveChannel.Server.admit`）。各家的工具命令得真是它的后代，否则这一家的动词全被拒。
@MainActor
@Suite(RealAgents.tiered)
struct RealLiveAgentTests {
    private final class Received: Sendable {
        private let box = Mutex<[String]>([])
        func add(_ session: String) { box.withLock { $0.append(session) } }
        var sessions: [String] { box.withLock { $0 } }
    }

    /// 各家跑命令的工具与参数（假模型照这个调）。Codex 申请在沙箱外跑（`codexEscalated`），由 CuePad 问用户。
    private nonisolated static func shell(_ agent: AgentKind, _ command: String) -> FakeReply {
        switch agent {
        case .pi: .call("bash", ["command": command])
        case .claudeCode: .call("Bash", ["command": command, "description": "live"])
        case .codex: codexEscalated(command)
        case .grok: .call("run_terminal_command", ["command": command, "description": "live"])
        case .dsh: .call("bash", ["command": command, "description": "live"])
        case .opencode: .call("shell", ["command": command, "description": "live"])
        }
    }

    @Test(arguments: AgentKind.allCases)
    func theToolCommandOfAHostedSessionOperatesItsOwnLivePreview(_ agent: AgentKind) async throws {
        try RealAgents.require(agent)
        let library = try Fixture()
        let received = Received()
        let server = try LiveChannel.Server(path: LiveChannel.socketPath(databasePath: library.store.databasePath), store: library.store) { request in
            received.add(request.session)
            return .done("PAGE-OK")
        }
        defer { withExtendedLifetime(server) {} }

        try await hosted(agent, library.store) { bridge, model, work, open in
            var mirror = SessionMirror(recorder: StateRecorder(store: library.store, hostID: "mac"))
            let changes = bridge.changes()
            let recording = Task { for await change in changes { _ = try? await mirror.apply(change) } }
            defer { recording.cancel() }
            let session = try #require(bridge.session(id: try await open()))
            try await eventually("会话记下了承载它的进程") { try await library.store.liveOwner(session.sessionID).process?.pid == session.pid }

            func run(_ name: String) -> (command: String, out: URL, err: URL) {
                let out = work.appending(path: "\(name).out"), err = work.appending(path: "\(name).err")
                let command = "CUEPAD_LIBRARY_DIR='\(library.directory.path)' '\(PiProcess.cuepad.path)' live snapshot > '\(out.path)' 2> '\(err.path)'; echo \"exit=$?\" >> '\(out.path)'"
                return (command, out, err)
            }
            // Codex 的工具命令默认跑在 workspace-write 沙箱里：连不上 CuePad，报错要说清是沙箱、让它申请在沙箱外跑
            let (sandboxed, (command, out, err)) = (run("sandboxed"), run("live"))
            let steps = agent == .codex ? [FakeReply.call("exec_command", ["cmd": sandboxed.command]), Self.shell(agent, command)] : [Self.shell(agent, command)]
            // 只答带工具的那一路：Claude Code 另有不带工具的辅助请求（起标题之类）也带着这句
            model.on({ !$0.tools.isEmpty && $0.prompt.contains("LIVE-CHECK") }) { $0.step < steps.count ? steps[$0.step] : .say("DONE") }
            try await bridge.send(SessionMessage(text: "LIVE-CHECK run it"), to: session.id)
            // 问要不要跑这条命令的（各家自己的权限规则、Codex 的沙箱外），照用户点允许
            try await eventually("工具命令跑完") {
                if let ask = bridge.session(id: session.id)?.question, let prompt = ask.promptID {
                    try await bridge.answer(.confirmed(true), to: prompt, in: session.id)
                }
                return (try? String(contentsOf: out, encoding: .utf8))?.contains("exit=") == true
            }
            if agent == .codex {
                let blocked = (try? String(contentsOf: sandboxed.err, encoding: .utf8)) ?? ""
                #expect(blocked.contains("沙箱不让这条命令连 CuePad"), "\(blocked)")
            }
            let printed = try String(contentsOf: out, encoding: .utf8)
            #expect(printed == "PAGE-OK\nexit=0\n", "\(printed)\n\((try? String(contentsOf: err, encoding: .utf8)) ?? "")")
            #expect(received.sessions == [session.sessionID])

            // 同一个会话号、不是它后代的进程（测试自己）：拒
            let stranger = Process()
            stranger.executableURL = PiProcess.cuepad
            stranger.arguments = ["live", "snapshot"]
            stranger.environment = ["CUEPAD_LIBRARY_DIR": library.directory.path, "CUEPAD_SESSION_ID": session.sessionID]
            let error = Pipe()
            stranger.standardError = error
            #expect(try await stranger.runToExit() == 1)
            let refusal = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(refusal.contains("只能操作自己会话的活预览"), "\(refusal)")
            #expect(received.sessions == [session.sessionID])
        }
    }

    /// 在这一家起好托管的接入，交出桥、假模型、工作目录与开一个托管会话的办法。
    private func hosted(
        _ agent: AgentKind, _ store: CueStore,
        _ body: (Bridge, FakeModel, URL, () async throws -> Session.ID) async throws -> Void
    ) async throws {
        switch agent {
        case .pi:
            let pi = try await PiProcess()
            let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
            defer { bridge.stop(); pi.stop() }
            try bridge.start()
            let host = PiRuntime(
                bridge: bridge, paths: pi.paths, brief: SessionBrief.text(cuepad: PiProcess.cuepad), pi: { pinnedPi.executable },
                idleLimit: .seconds(120), timing: noDeadline)
            host.start()
            defer { stopHostedProcesses(bridge) }
            try await body(bridge, pi.model, pi.cwd) { try await host.open(in: pi.cwd, launchToken: "t-live", name: nil, model: nil, thinking: nil) }
        case .opencode:
            let sandbox = try await OpenCodeSandbox()
            let bridge = Bridge(socketDirectory: sandbox.paths.pi.socketDirectory)
            let runtime = sandbox.runtime(bridge, store)
            let outcome: Result<Void, any Error>
            do {
                try runtime.start()
                try await body(bridge, sandbox.model, sandbox.work) {
                    try await runtime.open(in: sandbox.work, launchToken: "t-live", name: nil, model: nil, thinking: nil)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await runtime.stop()()
            try await sandbox.stop()
            try outcome.get()
        case .codex:
            try await withCodexRig(approvals: "on-request") { rig in
                try await body(rig.bridge, rig.model, rig.codex.work) {
                    try await rig.runtime.open(in: rig.codex.work, launchToken: "t-live", name: nil, model: nil, thinking: nil)
                }
            }
        case .claudeCode, .grok, .dsh:
            let hosting: Hosting = switch agent {
            case .claudeCode: .claude
            case .grok: .grok
            default: .dsh
            }
            try await EndRig.run(hosting, timing: .system, settings: #"{"permissions": {"allow": ["Bash"]}}"#) { rig in
                try await body(rig.bridge, rig.model, rig.work) { try await rig.open() }
            }
        }
    }
}
#endif
