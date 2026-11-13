#if os(macOS)
import CueStore
@testable import CueBridge
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct GlobalShortcutTests {
    @Test func 启动时按设置注册_更换成功才落设置_失败回滚() throws {
        let rig = TestApp()
        let defaults = rig.services.settings.defaults
        defaults.set("Control+Alt+KeyP", forKey: "slot")
        let hotkey = GlobalHotkey(label: "测试", slot: HotkeySlot(key: "slot", defaultAccelerator: "Alt+Space"), settings: rig.services.settings, backend: rig.hotkeys) {}
        try hotkey.registerSaved()
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 35, modifiers: [.control, .option])])

        try hotkey.set("Alt+KeyQ")
        #expect(defaults.string(forKey: "slot") == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option)])

        let taken = Shortcut(keyCode: 13, modifiers: .option)
        _ = try rig.hotkeys.register(taken) {}
        #expect(throws: HotkeyError.occupied(taken)) { try hotkey.set("Alt+KeyW") }
        #expect(hotkey.accelerator == "Alt+KeyQ" && defaults.string(forKey: "slot") == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option), taken])
    }

    @Test func 录新组合键时全部让出_撞上自己另一个快捷键报它的名字_录完都回来() throws {
        let rig = TestApp()
        let services: AppServices = rig.services
        let defaults = services.settings.defaults
        let before = rig.hotkeys.active
        let say = GlobalHotkey(label: "对 Cue 说", slot: HotkeySlot(key: "say", defaultAccelerator: "Alt+KeyQ"), settings: services.settings, backend: rig.hotkeys) {}
        let show = GlobalHotkey(label: "显示", slot: HotkeySlot(key: "show", defaultAccelerator: "Alt+KeyW"), settings: services.settings, backend: rig.hotkeys) {}
        services.register(say)
        services.register(show)
        let q = Shortcut(keyCode: 12, modifiers: .option), w = Shortcut(keyCode: 13, modifiers: .option)
        #expect(rig.hotkeys.active == before.union([q, w]))

        services.suspendHotkeys()
        #expect(rig.hotkeys.active.isDisjoint(with: [q, w]))
        #expect(throws: HotkeyError.taken("对 Cue 说")) { try services.rebind(show, to: "Alt+KeyQ") }
        try services.rebind(show, to: "Alt+KeyE")
        services.resumeHotkeys()

        #expect(rig.hotkeys.active == before.union([q, Shortcut(keyCode: 14, modifiers: .option)]))
        #expect(show.accelerator == "Alt+KeyE" && defaults.string(forKey: "show") == "Alt+KeyE")
    }
}

@Suite(.releasesLibraries)
struct HistoryPersistenceTests {
    private func sessionFile(in rig: TestApp, lines: [String]) throws -> URL {
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "s1.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let header = #"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/work/x"}"#
    private let firstPrompt = #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"fix the build","timestamp":1}}"#

    @Test func 回填完成后_不在会话列表里的旧行被删除() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        try await rig.services.store.upsertSession(IndexedSession(
            id: "worker-1", path: "/gone/--work-x--/subagents/w.jsonl", cwd: "/work/x", title: "子任务", lastActivityAt: .now), host: TestApp.hostID)
        let events = AsyncStream<HistoryEvent> { continuation in
            continuation.yield(.updated(try! History.index(file: file, agent: .pi, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumeHistory(events, agent: .pi)

        #expect(try await rig.services.store.indexedSessions().map(\.id) == ["sess-1"])
    }
}

@Suite(.releasesLibraries)
struct AgentLineTests {
    @Test func 各家接入后都写已接入与版本() async throws {
        let rig = TestApp()
        let pi = AgentKind.pi.facts.minimumVersion!.description
        let versions: [AgentKind: String] = [.pi: pi, .claudeCode: "2.1.299 (Claude Code)", .codex: "codex-cli 0.162.1", .opencode: "opencode v2.0.29",
            .grok: "grok 1.0.52 (0920c8169e27)", .dsh: "0.2.1-rc.4"]
        var lines: [String] = []
        for kind in AgentKind.allCases {
            try await rig.connect(kind, version: versions[kind]!)
            let agents = rig.services.agents
            lines.append(AgentLine.of(kind, agents.status(kind), writable: agents.isWritable(kind)).1?.visible ?? "")
        }

        #expect(lines == [
            "已接入 · Pi \(pi)", "已接入 · Claude Code 2.1.299", "已接入 · Codex 0.162.1", "已接入 · OpenCode 2.0.29", "已接入 · Grok Build 1.0.52",
            "已接入 · DeepSeek Harness 0.2.1-rc.4",
        ])
    }
}

@Suite(.releasesLibraries)
struct AgentUpgradeTests {
    @Test func 没接入过的Agent启动检查不写任何文件() async throws {
        let rig = TestApp()
        try FileManager.default.createDirectory(at: rig.directory.appending(path: "claude"), withIntermediateDirectories: true)

        try await rig.services.agents.refresh()

        #expect(rig.services.agents.status(.claudeCode) == AgentStatus(presence: .found(nil), files: .missing))
        #expect(FileManager.default.subpaths(atPath: rig.directory.appending(path: "claude").path) == [])
    }
}

@Suite(.releasesLibraries)
struct AgentIndexingTests {
    private func claudeSession(in rig: TestApp, id: String) throws {
        let project = rig.directory.appending(path: "claude/projects/-work-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let stamp = "2026-10-14T01:00:00.000Z"
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"\#(id)","cwd":"/work/x","timestamp":"\#(stamp)","message":{"role":"user","content":"修一下登录"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"\#(id)","cwd":"/work/x","timestamp":"\#(stamp)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"修好了"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: project.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// 没接入时那一遍回填只收 CuePad 托管过的会话（用户反馈：Cue 在没接入的 Claude Code 里开的会话做完、结束后，两端点进去都是空的）：
    /// 托管过的那个读得到对话，就说明这一遍回填已经看过整个目录，同目录里终端开的那个没进索引。
    @Test func 只有接入了的Agent建会话索引_托管过的不论接入都读得到_关掉删本地索引_同步记录留着() async throws {
        let rig = TestApp()
        let hosted = "6f1c0d2e-0000-4000-8000-000000000002", terminal = "6f1c0d2e-0000-4000-8000-000000000001"
        try claudeSession(in: rig, id: hosted)
        try claudeSession(in: rig, id: terminal)
        let services: AppServices = rig.services, store = services.store
        try await services.stateRecorder.update(sessionID: hosted, state: .settled, launchToken: "launch-1", hosted: true, agent: .claudeCode)
        try await services.stateRecorder.end(sessionID: hosted)
        services.start()
        defer { services.cancelBackgroundWork() }
        func indexed(_ ids: Set<String>) async throws {
            _ = try await eventually(store, { Set(try $0.indexedSessions().filter { $0.agent == .claudeCode }.map(\.id)) }) { $0 == ids }
        }

        let said = try await eventually(store, { try $0.chatMessages(of: hosted).map(\.text) }) { !$0.isEmpty }
        #expect(said == ["修一下登录", "修好了"])
        #expect(services.agents.status(.claudeCode)?.isConnected == false)
        #expect(try await Set(store.indexedSessions().filter { $0.agent == .claudeCode }.map(\.id)) == [hosted])

        try await rig.connect(.claudeCode)
        try await indexed([hosted, terminal])
        #expect(try await store.allSessionStates().contains { $0.sessionID == terminal })

        try await services.agents.uninstall(.claudeCode)
        try await indexed([hosted])
        #expect(try await store.allSessionStates().contains { $0.sessionID == terminal }, "同步出去的会话记录不动")

        try await services.agents.install(.claudeCode)
        try await indexed([hosted, terminal])
    }
}

@Suite(.releasesLibraries)
struct CueEnableTests {
    private func launch() async throws -> TestApp {
        let app = TestApp()
        app.services.startSync()
        try await app.syncs()
        return app
    }

    @Test func 启用不动你选的Agent与模型() async throws {
        let app = try await launch()
        try await app.connect(.pi)
        let services: AppServices = app.services, store = app.services.store
        func profile() async throws -> CueProfile { try #require(try await store.cueProfile()) }

        try await app.services.updateCue {
            $0.runtime = .known(.pi)
            $0.model = "fake/m"
            $0.effort = .known(.high)
        }
        try await services.enableCue(on: TestApp.hostID, moving: false)
        var now = try await profile()
        #expect(now.activeHost == TestApp.hostID && now.runtime == .known(.pi) && now.model == "fake/m" && now.effort == .known(.high))

        try await services.updateCue { $0.enabledAt = nil }
        try await services.enableCue(on: TestApp.hostID, moving: false)
        now = try await profile()
        #expect(now.activeHost == TestApp.hostID && now.model == "fake/m" && now.effort == .known(.high))

        try await app.services.updateCue { $0.runtime = .known(.claudeCode) }
        try await services.enableCue(on: TestApp.hostID, moving: false)
        now = try await profile()
        #expect(now.runtime == .known(.pi) && now.model == nil && now.effort == .known(.high))
    }

    @Test func 一家都不能用时启用报出各家为什么() async throws {
        let app = try await launch()
        await #expect {
            try await app.services.enableCue(on: TestApp.hostID, moving: false)
        } throws: {
            $0.localizedDescription == "没有能当 Cue 的 Agent：Pi 没装 · Claude Code 没装 · Codex 没装 · OpenCode 没装 · Grok Build 没装 · DeepSeek Harness 没装"
        }
        #expect(try await app.services.store.cueProfile()?.enabledAt == nil)
    }
}
#endif
