#if os(macOS)
import CueStore
@testable import CuePi
import Foundation
import Synchronization
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

struct ImageStoreTests {
    @Test func 编辑器存入的图片按内容哈希落入库并可读回() async throws {
        let rig = TestApp()
        let png = pngData()

        let id = try rig.services.store.files.store(png)

        #expect(id.count == 64)
        #expect(try rig.services.store.files.store(png) == id)
        #expect(try rig.services.store.files.original(hash: id) == png)
        let url = try #require(rig.services.store.files.fileURL(for: id))
        #expect(try Data(contentsOf: url) == png)
        #expect(rig.services.store.files.fileURL(for: String(repeating: "0", count: 64)) == nil)

        let file = rig.directory.appending(path: "dropped.png")
        let other = pngData(shade: 0.9)
        try other.write(to: file)
        let droppedID = try rig.services.store.files.store(fileAt: file)
        #expect(try rig.services.store.files.original(hash: droppedID) == other)
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
    private let reply = #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"done"}],"timestamp":2}}"#

    @Test func 索引结果与检查点写入本机会话表_重启后可从中断处继续() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        let events = AsyncStream<PiHistoryEvent> { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events, agent: .pi)

        let rows = try await rig.services.store.piSessions()
        #expect(rows.map(\.id) == ["sess-1"])
        #expect(rows[0].cwd == "/work/x")
        #expect(rows[0].path == file.path)
        #expect(rows[0].title == "fix the build")

        // 重启后从落盘的检查点继续：只读新增的字节
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((reply + "\n").utf8))
        try handle.close()
        let restarted = rig.relaunch()
        // 索引器按文件路径取检查点：重启后仍能对应到会话
        #expect(try await restarted.historyStore.checkpoint(for: file) != nil)
        let data = try #require(try await restarted.store.piCheckpoint(of: "sess-1"))
        let checkpoint = try JSONDecoder().decode(PiHistoryCheckpoint.self, from: data)
        let resumed = try PiHistory.index(file: file, from: checkpoint, files: rig.services.store.files)
        #expect(resumed.bytesRead == reply.utf8.count + 1)
        #expect(resumed.history.displayName == "fix the build")
    }

    /// 历史与 Pi 自己的会话列表一致：回填没看到的文件（已删除，或子代理会话这类不在会话列表里的）不再留在历史里。
    @Test func 回填完成后_不在会话列表里的旧行被删除() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        try await rig.services.store.upsertPiSession(IndexedSession(
            id: "worker-1", path: "/gone/--work-x--/subagents/w.jsonl", cwd: "/work/x", title: "子任务", lastActivityAt: .now), host: TestApp.hostID)
        let events = AsyncStream<PiHistoryEvent> { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events, agent: .pi)

        #expect(try await rig.services.store.piSessions().map(\.id) == ["sess-1"])
    }
}

struct AgentUpgradeTests {
    /// 装过的不再询问：App 更新后启动检查就把旧版的扩展静默升级到随包版本，缺的技能一起补上。
    @Test func 已装旧版扩展时启动检查静默升级到随包版本() async throws {
        let rig = TestApp()
        let bin = rig.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appending(path: "pi")
        try "#!/bin/sh\necho 0.90.0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let installed = rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
        try FileManager.default.createDirectory(at: rig.piPaths.extensionsDirectory, withIntermediateDirectories: true)
        let old = PiExtensionBundle.source.replacing(/const EXTENSION_VERSION = \d+;/, with: "const EXTENSION_VERSION = 1;")
        try old.write(to: installed, atomically: true, encoding: .utf8)

        try await rig.services.agents.refresh()

        #expect(rig.services.agents.status(.pi)?.files == .current)
        #expect(try String(contentsOf: installed, encoding: .utf8) == PiExtensionBundle.source)
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.skillsDirectory.appending(path: "cuepad/SKILL.md").path))
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

/// 查本机运行时的登录状态很慢（三家命令各最多 15 秒），只在启用、换运行时与大脑起不来时查。
struct CueRuntimeScanTests {
    @Test func 启动时Cue已在本机值班_不查运行时() async throws {
        let scans = Mutex(0)
        // 大脑一直在起：不走到"起不来"那条会查的路
        let app = TestApp(cue: CueDependencies(
            scan: { scans.withLock { $0 += 1 }; return [] }, launch: { _, _ in try? await Task.sleep(for: .seconds(2)); return nil },
            helper: URL(filePath: "/usr/bin/true"), notifier: RecordingCueNotifier()))
        try await app.services.store.updateCueProfile { [hostID = TestApp.hostID] in
            $0.hostID = hostID
            $0.enabledAt = .now
        }
        app.services.start()
        try await eventually("开始值班") { app.services.cue.state != nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(scans.withLock { $0 } == 0)
        #expect(app.services.cue.runtimes == nil)
        app.services.cancelBackgroundWork()
    }
}

/// 启用只是"住到这台、记下启用时刻"：你选的 Agent、模型、强度原样不动；选的 Agent 这台用不了才换成第一家能用的，
/// 模型属于原来那家，一并清掉，强度留着（交给运行时取档）。全新的设置强度是"低"（大脑默认要快）。
struct CueEnableTests {
    @Test func 全新设置启用后强度是低() async throws {
        let app = TestApp(cue: CueDependencies(
            scan: { [.pi] }, launch: { _, _ in nil }, helper: URL(filePath: "/usr/bin/true"), notifier: RecordingCueNotifier()))
        try await app.services.cue.enable()
        #expect(try await app.services.store.cueProfile()?.effort == .known(.low))
    }

    @Test func 启用不动你选的Agent与模型() async throws {
        let available = Mutex<[AgentKind]>([.pi])
        let app = TestApp(cue: CueDependencies(
            scan: { available.withLock { $0 } }, launch: { _, _ in nil }, helper: URL(filePath: "/usr/bin/true"), notifier: RecordingCueNotifier()))
        let cue = app.services.cue, store = app.services.store
        func profile() async throws -> CueProfile { try #require(try await store.cueProfile()) }

        try await cue.update {
            $0.runtime = .known(.pi)
            $0.model = "fake/m"
            $0.effort = .known(.high)
        }
        try await cue.enable()
        var now = try await profile()
        #expect(now.activeHost == TestApp.hostID && now.runtime == .known(.pi) && now.model == "fake/m" && now.effort == .known(.high))

        try await cue.disable()
        try await cue.enable()
        now = try await profile()
        #expect(now.activeHost == TestApp.hostID && now.model == "fake/m" && now.effort == .known(.high))

        try await cue.update { $0.runtime = .known(.claudeCode) }
        available.withLock { $0 = [.codex, .pi] }
        try await cue.enable()
        now = try await profile()
        #expect(now.runtime == .known(.codex) && now.model == nil && now.effort == .known(.high))
    }
}
#endif
