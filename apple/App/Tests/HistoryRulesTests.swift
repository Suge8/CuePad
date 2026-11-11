#if os(macOS)
import AppKit
import CueAgent
import CueBridge
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 真实 Pi 与真实后台托管（测闲置退出的用例闲置 2 秒就退），全部状态落在临时目录，假模型（`model`，回 `ECHO <你的话>`）零网络；不碰真实资料库与 ~/.pi。

@Suite(.releasesLibraries, .pinnedPi, .timeLimit(.minutes(4)))
struct HistoryRulesTests {
    final class Rig {
        let cwd: URL
        let host: PiRuntime
        let bridge: Bridge
        let services: AppServices
        let model: FakeModel
        var store: CueStore { services.store }

        init(providerFixture: URL? = nil, oauth: Bool = true, otherOAuthProviders: [String] = []) async throws {
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
            if let providerFixture {
                let directory = extensions.appending(path: "test-provider")
                try FileManager.default.copyItem(at: providerFixture.deletingLastPathComponent(), to: directory)
                try FileManager.default.moveItem(at: directory.appending(path: providerFixture.lastPathComponent), to: directory.appending(path: "index.ts"))
            }
            model = try await FakeModel()
            try Data(#"{"providers":{"fake":{"baseUrl":"\#(model.baseURL)/v1","api":"openai-completions","apiKey":"fake","models":[{"id":"echo","input":["text","image"]}]}}}"#.utf8)
                .write(to: paths.agentDirectory.appending(path: "models.json"))
            // 托管的 Pi 同真实用户一样读 agent 目录里的设置：默认假模型、不思考，不加载家目录里自动发现的 skill
            let provider = providerFixture == nil ? "fake" : "openai"
            try JSONSerialization.data(withJSONObject: [
                "defaultProvider": provider, "defaultModel": "echo", "defaultThinkingLevel": "off", "skills": ["!**"],
                "retry": ["enabled": false], "compaction": ["enabled": false],
            ]).write(to: paths.agentDirectory.appending(path: "settings.json"))
            if providerFixture != nil {
                let credential: [String: Any] = oauth
                    ? ["type": "oauth", "access": "synthetic-account-a", "refresh": "synthetic-refresh", "expires": 4_000_000_000_000]
                    : ["type": "api_key", "key": "synthetic-api-key"]
                var credentials = ["openai": credential]
                for provider in otherOAuthProviders {
                    credentials[provider] = ["type": "oauth", "access": "synthetic-\(provider)", "refresh": "synthetic-refresh", "expires": 4_000_000_000_000]
                }
                try JSONSerialization.data(withJSONObject: credentials).write(to: paths.agentDirectory.appending(path: "auth.json"))
            }

            bridge = Bridge(socketDirectory: paths.socketDirectory)
            host = PiRuntime(bridge: bridge, paths: paths, cleansInstalledExtension: true, pi: { realPi })
            let mac = MacDependencies(
                bridge: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents),
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
            LibraryLedger.tracking(services.store, createdAt: #_sourceLocation)
            services.start()
        }

        func shutdown() {
            // 托管的 Pi 不随 CuePad 结束：桥上还在的（本用例临时 socket 目录里的，是本用例启动的）逐个让它退出
            for session in bridge.sessions { kill(session.pid, SIGTERM) }
            let followers = services.cancelBackgroundWork(), finish = services.beginShutdown()
            LibraryLedger.close(LibraryLedger.current) {
                _ = await finish()
                await followers?.value
            }
        }

        func records(_ scope: SessionScope) async throws -> [SessionState] {
            try await store.sessionPage(SessionQuery(scope: scope, limit: .max)).items.map(\.state)
        }

        func replies(of sessionID: String) async throws -> [String] {
            guard let indexed = try await store.indexedSession(sessionID) else { return [] }
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

    @Test func 托管会话闲置退出后歇着_Cue与本机手机发话都唤醒它_用户结束才进历史() async throws {
        let rig = try await Rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "hosted", name: nil, model: nil, thinking: nil)
        let session = try #require(rig.bridge.session(id: id))
        let sessionID = session.sessionID
        _ = try await rig.bridge.send(SessionMessage(text: "开场"), to: id)
        try await eventually("回答落盘、索引跟上") { try await rig.replies(of: sessionID).last == "ECHO 开场" }

        try await idleExit(rig, sessionID)
        let rested = try await expectResting(rig, sessionID)

        let host = TestApp.hostID
        _ = try await rig.store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let said = try #require(await CueTools(store: rig.store).call("task", ["action": "say", "session": rested.shortID, "text": "Cue 来的话"]))
        #expect(!said.isError, "\(said.text)")
        try await eventually("Cue 说的话得到回复") { try await rig.replies(of: sessionID).last == "ECHO Cue 来的话" }
        try await idleExit(rig, sessionID)
        try await expectResting(rig, sessionID)

        // Mac 本机发话（"已结束"那条路：执行器用会话索引在后台唤醒）
        Workspace(services: rig.services).send("本机来的话", to: AgentTarget(session: sessionID))
        try await eventually("本机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 本机来的话" }
        try await idleExit(rig, sessionID)
        let resting = try await expectResting(rig, sessionID)

        let request = try await rig.store.requestDelivery("手机来的话", to: resting.target, on: resting.hostID, mode: .send)
        let result = try await rig.services.store.outcome(of: request)
        #expect(result.failure == nil)
        try await eventually("手机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 手机来的话" }
        try await idleExit(rig, sessionID)
        let again = try await expectResting(rig, sessionID)

        let end = try await rig.services.end(again)
        #expect(try await rig.services.store.outcome(of: end).failure == nil)
        try await eventually("结束后进历史") { try await rig.records(.ended).map(\.sessionID) == [sessionID] }
        #expect(try await rig.records(.live).isEmpty)
    }

    /// 闲置到点时扩展做的事就是给自己发 SIGTERM（lifecycle.ts 的 IdleExit）；到点本身由 CueBridgeTests 的 anIdleHostedSessionExitsAfterTheIdleLimit 守，
    /// 这里歇下就直接发，不等墙钟（托管的闲置时限最小一秒，四次就是好几秒）。
    private func idleExit(_ rig: Rig, _ sessionID: String) async throws {
        try await eventually("这一轮歇下") { rig.bridge.session(sessionID: sessionID)?.state == .settled }
        kill(try #require(rig.bridge.session(sessionID: sessionID)).pid, SIGTERM)
        try await eventually("闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
    }

    @discardableResult
    private func expectResting(_ rig: Rig, _ sessionID: String) async throws -> SessionState {
        let current = try await rig.store.sessionPage(.current).items.map(\.state)
        let state = try #require(current.first { $0.sessionID == sessionID }, "仍在现在")
        #expect(state.hosted && state.runtimeState == .known(.settled), "托管、歇着")
        let shown = Workspace(services: rig.services).shown(state, delivery: nil)
        #expect([.idle, .unread, .resting, .awaitsReply].contains(shown.status), "界面写的是「\(shown.label)」")
        #expect(try await rig.records(.ended).isEmpty, "不进历史")
        return state
    }
}
#endif
