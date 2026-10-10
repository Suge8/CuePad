#if os(macOS)
import struct CueStore.PiSession
import CueStore
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

@MainActor
struct GlobalShortcutTests {
    @Test(arguments: [
        ("Alt+Space", Shortcut(keyCode: 49, modifiers: .option)),
        ("Control+Alt+Shift+Super+KeyK", Shortcut(keyCode: 40, modifiers: [.control, .option, .shift, .command])),
        ("Super+ArrowUp", Shortcut(keyCode: 126, modifiers: .command)),
        ("Control+F1", Shortcut(keyCode: 122, modifiers: .control)),
        ("Shift+Digit1", Shortcut(keyCode: 18, modifiers: .shift)),
    ])
    func 加速键字符串与快捷键互转(accelerator: String, shortcut: Shortcut) {
        #expect(Shortcut(accelerator: accelerator) == shortcut)
        #expect(shortcut.accelerator == accelerator)
    }

    @Test(arguments: ["Space", "Alt", "Alt+Escape", "Hyper+KeyA", ""])
    func 不支持的加速键被拒绝(accelerator: String) {
        #expect(Shortcut(accelerator: accelerator) == nil)
    }

    @Test func 启动时按设置注册_更换成功才落设置_失败回滚() throws {
        let rig = TestApp()
        let services: AppServices = rig.services
        services.settings.globalShortcut = "Control+Alt+KeyP"
        services.applySavedShortcut()
        let saved = Shortcut(keyCode: 35, modifiers: [.control, .option])
        #expect(rig.hotkeys.active == [saved])

        try services.setGlobalShortcut("Alt+KeyQ")
        #expect(services.settings.globalShortcut == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option)])

        // 另一个组合已被占用：抛错，旧的继续生效，设置不变
        let taken = Shortcut(keyCode: 13, modifiers: .option)
        _ = try rig.hotkeys.register(taken) {}
        #expect(throws: HotkeyError.occupied(taken)) { try services.setGlobalShortcut("Alt+KeyW") }
        #expect(services.settings.globalShortcut == "Alt+KeyQ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 12, modifiers: .option), taken])
    }
}

@MainActor
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

@MainActor
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
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events)

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
        let resumed = try PiHistory.index(file: file, from: checkpoint)
        #expect(resumed.bytesRead == reply.utf8.count + 1)
        #expect(resumed.history.displayName == "fix the build")
    }

    /// 历史与 Pi 自己的会话列表一致：回填没看到的文件（已删除，或子代理会话这类不在会话列表里的）不再留在历史里。
    @Test func 回填完成后_不在会话列表里的旧行被删除() async throws {
        let rig = TestApp()
        let file = try sessionFile(in: rig, lines: [header, firstPrompt])
        try await rig.services.store.upsertPiSession(PiSession(
            id: "worker-1", path: "/gone/--work-x--/subagents/w.jsonl", cwd: "/work/x", title: "子任务", lastActivityAt: .now), host: TestApp.hostID)
        let events = AsyncStream<PiHistoryEvent> { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events)

        #expect(try await rig.services.store.piSessions().map(\.id) == ["sess-1"])
    }
}

@MainActor
struct PiExtensionConsentTests {
    private func rigWithPi(version: String) throws -> TestApp {
        let rig = TestApp()
        let bin = rig.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appending(path: "pi")
        try "#!/bin/sh\necho \(version)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return rig
    }

    /// 询问卡片读 `needsConsent`：拒绝后它必须作为可观察的变化通知界面，卡片才会立即收起（之前要重启才消失）。
    @Test func 拒绝后询问的变化能被界面观察到() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let manager = rig.services.piIntegration
        try await manager.refresh()
        let changed = Flag()
        withObservationTracking { _ = manager.needsConsent } onChange: { changed.set() }

        manager.decline()

        #expect(changed.value)
        #expect(!manager.needsConsent)
    }

    nonisolated private final class Flag: @unchecked Sendable {
        private(set) var value = false
        func set() { value = true }
    }

    @Test func 缺扩展时征求同意_拒绝后不再提示也不安装_同意后安装() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let manager = rig.services.piIntegration

        try await manager.refresh()
        #expect(manager.needsConsent)

        manager.decline()
        try await manager.refresh()
        #expect(!manager.needsConsent)
        #expect(manager.status?.file == .missing)  // 拒绝过首次安装：维持不装

        #expect(!FileManager.default.fileExists(atPath: rig.piPaths.skillsDirectory.path))  // 拒绝：扩展与 skill 都不装

        try await manager.install()
        #expect(manager.status?.file == .current)
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts").path))
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.skillsDirectory.appending(path: "cuepad/SKILL.md").path))
    }

    @Test func Pi_版本过低或不存在时不征求同意() async throws {
        let tooOld = try rigWithPi(version: "0.80.0")
        try await tooOld.services.piIntegration.refresh()
        #expect(!tooOld.services.piIntegration.needsConsent)

        let absent = TestApp()
        try await absent.services.piIntegration.refresh()
        #expect(!absent.services.piIntegration.needsConsent)
    }

    /// 同意只在首次安装时问一次：已装的是我们的旧版扩展时，启动检查就静默升级到随包版本，不再询问。
    @Test func 已装旧版扩展时启动检查静默升级到随包版本() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let installed = rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
        try FileManager.default.createDirectory(at: rig.piPaths.extensionsDirectory, withIntermediateDirectories: true)
        let old = PiExtensionBundle.source.replacing(/const EXTENSION_VERSION = \d+;/, with: "const EXTENSION_VERSION = 1;")
        try old.write(to: installed, atomically: true, encoding: .utf8)

        try await rig.services.piIntegration.refresh()

        #expect(rig.services.piIntegration.status?.file == .current)
        #expect(try String(contentsOf: installed, encoding: .utf8) == PiExtensionBundle.source)
        #expect(!rig.services.piIntegration.needsConsent)
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.skillsDirectory.appending(path: "cuepad/SKILL.md").path))  // 旧版用户升级时补上 skill
    }
}
#endif
