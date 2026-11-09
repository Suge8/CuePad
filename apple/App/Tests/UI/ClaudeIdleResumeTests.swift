#if os(macOS)
import AppKit
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// 托管的真 Claude Code（钉住的版本，`ClaudeSandbox` 隔离、假模型回 `ECHO <你的话>`）歇满空闲时限被请退出、进程还没走的那段里，
/// 从 Mac 本机发话：投送接着这个会话、得到回复，旧进程收掉（不是报"会话已经结束"）。
/// 外壳（`wrapper`）起的托管进程在 Claude Code 读到 EOF 退出后（`eof.<pid>`：CuePad 已请它退出；pid 是外壳的，也是桥上记的）
/// 一直握着输出、不自己走：只有 CuePad 收它才会结束。只看这个会话的：App 起来时问登录与模型清单也起一个、问完就关（`AgentFacts.probe`）。
@Suite(.enabled(if: PinnedAgent.claude.uncovered == nil, Comment(rawValue: PinnedAgent.claude.uncovered ?? "")), .timeLimit(.minutes(4)))
@MainActor
struct ClaudeIdleResumeTests {
    @Test func 托管会话请退出还没走时本机发话_接着它得到回复_旧进程收掉() async throws {
        try await Rig.run { rig in try await idleThenSay(rig) }
    }

    private func idleThenSay(_ rig: Rig) async throws {
        let id = try await rig.runtime.open(in: rig.work, launchToken: "hosted", name: nil, model: nil, thinking: nil)
        let session = try #require(rig.bridge.session(id: id))
        let sessionID = session.sessionID
        try await rig.bridge.send(PiMessage(text: "开场"), to: id)
        // 第一句话前 Claude Code 自己加了一段 system-reminder，假模型照样回声
        try await eventually("回答落盘、索引跟上") { try await rig.replies(of: sessionID).last?.hasSuffix("开场") == true }

        try await eventually("空闲到点，请它退出了") { rig.hasFile("eof.\(session.pid)") }
        #expect(rig.bridge.session(sessionID: sessionID) == nil, "请它退出了还在桥上")
        await Workspace(services: rig.services).send("闲置后的话", to: AgentTarget(session: sessionID)).value
        let request = try #require(try await rig.store.deliveryRequests(toSession: sessionID).last)
        let result = try await rig.store.outcome(of: request)

        #expect(result.status == .known(.succeeded), "\(result.reason.map(String.init(describing:)) ?? "")")
        try await eventually("闲置后的话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 闲置后的话" }
        #expect(kill(session.pid, 0) != 0, "旧进程还在")
        #expect(rig.bridge.session(sessionID: sessionID).map { $0.pid != session.pid } == true, "接着它的是新进程")
    }

    final class Rig {
        let work: URL
        let wrapper: URL
        let bridge: PiBridge
        let hooks: AgentHookServer
        let services: AppServices
        let model: FakeModel
        var store: CueStore { services.store }

        init() async throws {
            try PinnedAgent.claude.require()
            let root = TestLibraries.makeDirectory()
            let workDirectory = root.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
            model = try await FakeModel()
            let isolated = ClaudeSandbox.environment(model: model, root: root)
            try ClaudeSandbox.seed(config: root.appending(path: "config"), trusting: work)
            wrapper = root.appending(path: "wrapper", directoryHint: .isDirectory)
            try TestScript.install(
                #"#!/bin/sh"# + "\n" + #". "$0.env"; [ "$1" = --input-format ] || exec "$REAL" "$@"; dir=${0%/*}; echo $$ >> "$dir/pids"; "#
                    + #""$REAL" "$@"; : > "$dir/eof.$$"; while :; do sleep 1; done"# + "\n",
                at: wrapper.appending(path: "claude"), variables: ["REAL": PinnedAgent.claude.executable.path])
            let paths = PiPaths(
                agentDirectory: root.appending(path: "pi"),
                socketDirectory: URL(filePath: "/tmp/cir-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory),
                binDirectory: root.appending(path: "home/.local/bin"))
            // 其余 Agent 的目录也指到临时目录：不读这台 Mac 上真实的会话
            let agentPaths = AgentPaths(pi: paths, environment: isolated.merging([
                "CODEX_HOME": root.appending(path: "codex").path, "OPENCODE_CONFIG_DIR": root.appending(path: "opencode").path,
                "GROK_HOME": root.appending(path: "grok").path, "CUEPAD_AGENTS_DIR": root.appending(path: "agents").path,
                "DSH_HOME": root.appending(path: "dsh").path,
            ]) { $1 })
            let agents = AgentIntegration(
                paths: agentPaths, locate: { [wrapper] in ExecutableLocator(searchDirectories: [wrapper]) },
                cuepad: root.appending(path: "CuePad.app/Contents/Helpers/cuepad"))
            bridge = PiBridge(socketDirectory: paths.socketDirectory, hostedIdle: .seconds(3))
            hooks = AgentHookServer(path: paths.hookSocket)
            let mac = MacDependencies(
                pi: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents), terminal: PiTerminalJumper(),
                hostID: TestApp.hostID, workspaces: Workspaces(root: root.appending(path: "CuePad", directoryHint: .isDirectory)),
                wakeNotifications: NotificationCenter(),
                commandLineTool: CommandLineToolInstaller(
                    helper: root.appending(path: "CuePad.app/Contents/Helpers/cuepad"),
                    linkDirectory: root.appending(path: "home/.local/bin"), shellPath: { nil }),
                updater: nil, hooks: hooks,
                runtimes: { [bridge, hooks, wrapper] store in [.claudeCode: ClaudeCodeRuntime(
                    bridge: bridge, paths: agentPaths, hooks: hooks, store: store, claude: { wrapper.appending(path: "claude") },
                    locate: { ExecutableLocator(searchDirectories: [wrapper]) })] }, pasteboard: NSPasteboard(name: .init("cir-\(UUID().uuidString)")),
                cue: CueDependencies(launch: { _, _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
            let location = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: root.appending(path: "Library").path])
            services = try AppServices(location: location, defaults: TempDefaults().defaults, sync: .custom(FakeSync()), mac: mac)
            services.start()
        }

        var runtime: ClaudeCodeRuntime { services.runtimes[.claudeCode] as! ClaudeCodeRuntime }

        /// 搭好跑 `body`，不论成败都收掉起的进程（临时目录随测试进程退出整体删除）。
        static func run(_ body: (Rig) async throws -> Void) async throws {
            let rig = try await Rig()
            do { try await body(rig) } catch {
                await rig.shutdown()
                throw error
            }
            await rig.shutdown()
        }

        /// 外壳每起一个托管进程（`ClaudeStream`）记下的 pid（先后）；问版本、列会话的不记
        var pids: [Int32] {
            ((try? String(contentsOf: wrapper.appending(path: "pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        }

        func hasFile(_ name: String) -> Bool { FileManager.default.fileExists(atPath: wrapper.appending(path: name).path) }

        /// 托管的进程按 runtime 的收法收；收不掉的外壳（修坏了的那种）按记下的 pid 结束。
        func shutdown() async {
            services.cancelBackgroundWork()
            await runtime.stop()()
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            hooks.stop()
            bridge.stop()
        }

        func replies(of sessionID: String) async throws -> [String] {
            guard let indexed = try await store.piSession(sessionID) else { return [] }
            let text = (try? String(contentsOf: URL(filePath: indexed.path), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let blocks = message["content"] as? [[String: Any]] else { return nil }
                return blocks.compactMap { $0["text"] as? String }.joined()
            }
        }
    }
}
#endif
