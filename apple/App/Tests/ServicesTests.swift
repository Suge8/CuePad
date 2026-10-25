#if os(macOS)
import CueStore
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

struct GlobalShortcutTests {
    @Test func 启动时按设置注册_更换成功才落设置_失败回滚() throws {
        let rig = TestApp()
        let defaults = rig.services.settings.defaults
        defaults.set("Control+Alt+KeyP", forKey: "slot")
        let hotkey = GlobalHotkey(label: "测试", key: "slot", defaultAccelerator: "Alt+Space", defaults: defaults, backend: rig.hotkeys) {}
        try hotkey.registerSaved()
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 35, modifiers: [.control, .option])])

        try hotkey.set("Alt+KeyQ")
        #expect(defaults.string(forKey: "slot") == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option)])

        // 另一个组合已被占用：抛错，旧的继续生效，设置不变
        let taken = Shortcut(keyCode: 13, modifiers: .option)
        _ = try rig.hotkeys.register(taken) {}
        #expect(throws: HotkeyError.occupied(taken)) { try hotkey.set("Alt+KeyW") }
        #expect(hotkey.accelerator == "Alt+KeyQ" && defaults.string(forKey: "slot") == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option), taken])
    }
}

struct PiHistoryPersistenceTests {
    private func sessionFile(in rig: TestApp, lines: [String]) throws -> URL {
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "s1.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let header = #"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/work/x"}"#
    private let firstPrompt = #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"fix the build","timestamp":1}}"#

    /// 续读从检查点接着读（读多少由 CuePiTests 的 HistoryTests 证明）：这里只管检查点落进本机会话表、重启后按文件路径取得回来。
    @Test func 索引结果与检查点写入本机会话表_重启后按文件取得回检查点() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        let events = AsyncStream<PiHistoryEvent> { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events, agent: .pi)

        let rows = try await rig.services.store.piSessions()
        #expect(rows.map(\.id) == ["sess-1"])
        #expect(rows[0].cwd == "/work/x")
        #expect(rows[0].path == file.path)
        #expect(rows[0].title == "fix the build")
        #expect(try await rig.relaunch().historyStore.start(for: file)?.checkpoint != nil)
    }

    /// 历史与 Pi 自己的会话列表一致：回填没看到的文件（已删除，或子代理会话这类不在会话列表里的）不再留在历史里。
    @Test func 回填完成后_不在会话列表里的旧行被删除() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        try await rig.services.store.upsertPiSession(IndexedSession(
            id: "worker-1", path: "/gone/--work-x--/subagents/w.jsonl", cwd: "/work/x", title: "子任务", lastActivityAt: .now), host: TestApp.hostID)
        let events = AsyncStream<PiHistoryEvent> { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events, agent: .pi)

        #expect(try await rig.services.store.piSessions().map(\.id) == ["sess-1"])
    }
}

/// 设置里四家接入后的那一行是同一种写法：已接入 · 名字与版本（各家 `--version` 的原话各不相同）；写在哪、何时生效在悬停提示里。
struct AgentLineTests {
    @Test func 四家接入后都写已接入与版本() async throws {
        let rig = TestApp()
        let versions: [AgentKind: String] = [.pi: "1.2.0", .claudeCode: "2.1.299 (Claude Code)", .codex: "codex-cli 0.162.1", .opencode: "opencode v2.0.29"]
        var lines: [String] = []
        for kind in AgentKind.allCases {
            try await rig.connect(kind, version: versions[kind]!)
            let agents = rig.services.agents
            lines.append(AgentLine.of(kind, agents.status(kind), writable: agents.isWritable(kind)).1?.visible ?? "")
        }

        #expect(lines == ["已接入 · Pi 1.2.0", "已接入 · Claude Code 2.1.299", "已接入 · Codex 0.162.1", "已接入 · OpenCode 2.0.29"])
    }
}

struct AgentUpgradeTests {
    /// 装过的不再询问：App 更新后启动检查就把旧版的扩展静默升级到随包版本，缺的技能一起补上。
    /// 旧版是单文件扩展（v37 及更早）：装上目录，没有 Pi 会话开着旧扩展就删掉旧文件，扩展目录里只剩一份。
    @Test func 已装旧版扩展时启动检查静默升级到随包版本() async throws {
        let rig = TestApp()
        try TestScript.install("#!/bin/sh\necho 0.90.0\n", at: rig.directory.appending(path: "bin/pi"))
        let legacy = rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
        try FileManager.default.createDirectory(at: rig.piPaths.extensionsDirectory, withIntermediateDirectories: true)
        try "\(PiExtensionBundle.ownershipMarker)\nconst EXTENSION_VERSION = 37;\n".write(to: legacy, atomically: true, encoding: .utf8)

        try await rig.services.agents.refresh()

        #expect(rig.services.agents.status(.pi)?.files == .current)
        let entry = rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge/index.ts")
        #expect(try String(contentsOf: entry, encoding: .utf8) == PiExtensionBundle.entry)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.agentDirectory.appending(path: "skills/cuepad/SKILL.md").path))
    }

    /// 没装过的不碰：检测完什么都不写，等用户自己接入。
    @Test func 没接入过的Agent启动检查不写任何文件() async throws {
        let rig = TestApp()
        try FileManager.default.createDirectory(at: rig.directory.appending(path: "claude"), withIntermediateDirectories: true)

        try await rig.services.agents.refresh()

        #expect(rig.services.agents.status(.claudeCode) == AgentStatus(presence: .found(nil), files: .missing))
        #expect(FileManager.default.subpaths(atPath: rig.directory.appending(path: "claude").path) == [])
    }
}

/// "接入"管终端里的会话与历史：整个会话目录只为接入了的 Agent 回填，关掉时删掉这家的本地索引，同步出去的会话记录不动。
/// CuePad 托管过的会话不论接入都读得到对话。
struct AgentIndexingTests {
    /// 在 Claude Code 的配置目录里放一个做完一轮的会话文件。
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
        try await services.piStateRecorder.update(sessionID: hosted, state: .settled, launchToken: "launch-1", hosted: true, agent: .claudeCode)
        try await services.piStateRecorder.end(sessionID: hosted)
        services.start()
        defer { services.cancelBackgroundWork() }
        func indexed(_ ids: Set<String>) async throws {
            _ = try await eventually(store, { Set(try $0.piSessions().filter { $0.agent == .claudeCode }.map(\.id)) }) { $0 == ids }
        }

        let said = try await eventually(store, { try $0.piMessages(of: hosted).map(\.text) }) { !$0.isEmpty }
        #expect(said == ["修一下登录", "修好了"])
        #expect(services.agents.status(.claudeCode)?.isConnected == false)
        #expect(try await Set(store.piSessions().filter { $0.agent == .claudeCode }.map(\.id)) == [hosted])

        try await rig.connect(.claudeCode)
        try await indexed([hosted, terminal])
        #expect(try await store.allPiSessionStates().contains { $0.sessionID == terminal })

        try await services.agents.uninstall(.claudeCode)
        try await indexed([hosted])
        #expect(try await store.allPiSessionStates().contains { $0.sessionID == terminal }, "同步出去的会话记录不动")

        // 再接入：从头回填回来
        try await services.agents.install(.claudeCode)
        try await indexed([hosted, terminal])
    }
}

/// 启用只是"换到这台运行、记下启用时刻"：你选的 Agent、模型、强度原样不动；选的 Agent 这台用不了（启用时重新问出的这台 Mac 上能用的
/// Agent 里没有它）才换成第一家能用的，模型属于原来那家，一并清掉，强度留着（交给运行时取档）。
/// 一家都不能用时报出各家为什么。
struct CueEnableTests {
    /// 起一个对过 iCloud 的 App（启用的前提）。
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
            $0.localizedDescription == "没有能当 Cue 的 Agent：Pi 没装 · Claude Code 没装 · Codex 没装 · OpenCode 没装"
        }
        #expect(try await app.services.store.cueProfile()?.enabledAt == nil)
    }
}
#endif
