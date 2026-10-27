#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// "什么算历史"的两条规则，端到端用真实 Pi：一句话没说过的会话关掉后不进历史；CuePad 后台托管的会话闲置退出不算结束，
/// 仍在"现在"，Mac 本机与手机两条路发话都会唤醒它，只有用户结束它才进历史。
/// 真实 Pi 与真实后台托管（测闲置退出的用例闲置 2 秒就退），全部状态落在临时目录，假模型零网络；不碰真实资料库与 ~/.pi。
nonisolated private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "CuePadKit/Tests/CuePiTests/Fixtures")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .timeLimit(.minutes(4)))
struct HistoryRulesTests {
    final class Rig {
        let cwd: URL
        let host: PiRuntime
        let bridge: PiBridge
        let services: AppServices
        var store: CueStore { services.store }

        init(idleLimit: Duration = AgentTimeouts.hostedIdle) async throws {
            let directory = TestLibraries.makeDirectory()
            cwd = directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let paths = PiPaths(
                agentDirectory: directory.appending(path: "agent"),
                socketDirectory: URL(filePath: "/tmp/hr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory),
                binDirectory: directory.appending(path: "home/.local/bin"))
            // 其余 Agent 的目录也指到临时目录：不读这台 Mac 上真实的会话
            let agentPaths = AgentPaths(pi: paths, environment: [
                "CLAUDE_CONFIG_DIR": directory.appending(path: "claude").path, "CODEX_HOME": directory.appending(path: "codex").path,
                "OPENCODE_CONFIG_DIR": directory.appending(path: "opencode").path, "GROK_HOME": directory.appending(path: "grok").path,
                "XDG_STATE_HOME": directory.appending(path: "state").path, "CUEPAD_AGENTS_DIR": directory.appending(path: "agents").path,
                "DSH_HOME": directory.appending(path: "dsh").path,
            ])
            let agents = AgentIntegration(
                paths: agentPaths, locate: { ExecutableLocator(searchDirectories: [realPi.deletingLastPathComponent()]) },
                cuepad: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad"))
            try await agents.install(.pi)
            let extensions = paths.agentDirectory.appending(path: "extensions")
            try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appending(path: "fake-model.ts"), to: extensions.appending(path: "fake-model.ts"))
            // 托管的 Pi 同真实用户一样读 agent 目录里的设置：默认假模型、不思考，不加载家目录里自动发现的 skill
            try JSONSerialization.data(withJSONObject: ["defaultProvider": "fake", "defaultModel": "echo", "defaultThinkingLevel": "off", "skills": ["!**"]])
                .write(to: paths.agentDirectory.appending(path: "settings.json"))
            _ = Self.offline

            bridge = PiBridge(socketDirectory: paths.socketDirectory)
            host = PiRuntime(bridge: bridge, paths: paths, pi: { realPi }, idleLimit: idleLimit)
            let mac = MacDependencies(
                pi: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents), terminal: PiTerminalJumper(),
                hostID: TestApp.hostID, workspaces: Workspaces(root: directory.appending(path: "CuePad", directoryHint: .isDirectory)),
                wakeNotifications: NotificationCenter(),
                commandLineTool: CommandLineToolInstaller(
                    helper: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad"),
                    linkDirectory: directory.appending(path: "home/.local/bin"), shellPath: { nil }),
                updater: nil, hooks: AgentHookServer(path: paths.hookSocket),
                runtimes: { [host] _ in [.pi: host] }, pasteboard: NSPasteboard(name: .init("hr-\(UUID().uuidString)")),
                cue: CueDependencies(launch: { _, _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
            let location = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
            services = try AppServices(location: location, defaults: TempDefaults().defaults, sync: .custom(FakeSync()), mac: mac)
            services.start()
        }

        /// 不联网：Pi 只认 `PI_OFFLINE`（没有设置项），托管的 Pi 继承 CuePad 进程的环境，所以设在本测试进程上（只有 Pi 读它）。
        static let offline: Void = { setenv("PI_OFFLINE", "1", 1) }()

        func shutdown() {
            services.cancelBackgroundWork()
            // 托管的 Pi 不随 CuePad 结束：桥上还在的（本用例临时 socket 目录里的，是本用例启动的）逐个让它退出
            for session in bridge.sessions where session.hosted { kill(session.pid, SIGTERM) }
            bridge.stop()
        }

        func records(_ scope: PiSessionScope) async throws -> [PiSessionState] {
            try await store.piSessionPage(PiSessionQuery(scope: scope, limit: .max)).items.map(\.state)
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

    // MARK: 一句话没说过的会话

    @Test func 一句话没说过的会话关掉后不进历史() async throws {
        let rig = try await Rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "silent", name: nil, model: nil, thinking: nil)
        try await eventually("会话记录写出") { try await rig.records(.all).count == 1 }

        try await rig.bridge.end(id)

        try await eventually("没说过话的会话记录被删（同步删除）") { try await rig.records(.all).isEmpty }
    }

    // MARK: 后台托管的会话闲置退出

    @Test func 托管会话闲置退出后仍在现在_发话唤醒回复_用户结束才进历史() async throws {
        let rig = try await Rig(idleLimit: .seconds(2))
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "hosted", name: nil, model: nil, thinking: nil)
        let session = try #require(rig.bridge.session(id: id))
        let sessionID = session.sessionID
        _ = try await rig.bridge.send(PiMessage(text: "开场"), to: id)
        try await eventually("回答落盘、索引跟上") { try await rig.replies(of: sessionID).last == "ECHO 开场 IMAGES[]" }

        // 闲置退出：进程不在了，会话仍在"现在"，歇着，不进历史
        try await eventually("闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        try await expectResting(rig, sessionID)

        // Mac 本机发话（"已结束"那条路：执行器用会话索引在后台唤醒）
        Workspace(services: rig.services).send("本机来的话", to: AgentTarget(session: sessionID))
        try await eventually("本机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 本机来的话 IMAGES[]" }
        try await eventually("再次闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        let resting = try await expectResting(rig, sessionID)

        // 手机发话（投送请求写给这台 Mac）
        let request = try await rig.store.requestDelivery("手机来的话", to: resting.target, on: resting.hostID, mode: .send)
        let result = try await rig.services.store.outcome(of: request)
        #expect(result.failure == nil)
        try await eventually("手机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 手机来的话 IMAGES[]" }
        try await eventually("又一次闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        let again = try await expectResting(rig, sessionID)

        // 用户在 CuePad 里结束它：这时才进历史
        let end = try await rig.services.end(again)
        #expect(try await rig.services.store.outcome(of: end).failure == nil)
        try await eventually("结束后进历史") { try await rig.records(.ended).map(\.sessionID) == [sessionID] }
        #expect(try await rig.records(.live).isEmpty)
    }

    /// 进程不在了、记录仍在"现在"（未结束）、不在历史里、是托管的、歇着。
    @discardableResult
    private func expectResting(_ rig: Rig, _ sessionID: String) async throws -> PiSessionState {
        let current = try await rig.store.piSessionPage(.current).items.map(\.state)
        let state = try #require(current.first { $0.sessionID == sessionID }, "仍在现在")
        #expect(state.hosted && state.state == .known(.settled), "托管、歇着")
        #expect(try await rig.records(.ended).isEmpty, "不进历史")
        return state
    }
}

/// 托管开新会话：参数不对时 Pi 起来就退出，带着 Pi 的原话报错，桥上不留会话。
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"))
struct HostedLaunchTests {
    @Test func 开新会话模型无效时整体失败() async throws {
        let directory = TestLibraries.makeDirectory()
        let paths = PiPaths(
            agentDirectory: directory.appending(path: "agent"),
            socketDirectory: URL(filePath: "/tmp/hl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory),
            binDirectory: directory.appending(path: "bin"))
        let bridge = PiBridge(socketDirectory: paths.socketDirectory)
        try bridge.start()
        defer { bridge.stop() }
        let host = PiRuntime(bridge: bridge, paths: paths, pi: { realPi })
        await #expect(throws: PiHostError.exited(#"Error: Model "nope/x" not found. Use --list-models to see available models."#)) {
            _ = try await host.open(in: directory, launchToken: "t", name: "修登录页", model: PiModelKey(provider: "nope", id: "x"), thinking: nil)
        }
        #expect(bridge.sessions.isEmpty)
    }
}
#endif
