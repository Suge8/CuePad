#if os(macOS)
import CueStore
import CuePi
import Foundation
import Testing
@testable import CuePad

@MainActor
struct LegacyImportTests {
    @Test func 首次启动导入旧库并采用其主题与快捷键_再次启动不重复导入() async throws {
        let legacy = try makeLegacyDatabase(settings: ["theme": "\"dark\"", "globalShortcut": "\"Alt+KeyZ\""])
        let rig = TestApp(legacy: legacy)

        await rig.services.importLegacyIfNeeded()

        #expect(try await rig.services.store.projects().map(\.name) == ["Career", "Flow"])
        #expect(try await rig.services.store.tasks().map(\.content) == ["first"])
        #expect(rig.services.settings.theme == .dark)
        #expect(rig.services.settings.globalShortcut == "Alt+KeyZ")
        #expect(rig.hotkeys.active == [Shortcut(keyCode: 6, modifiers: .option)])

        // 用户在新版里永久删除后，再次启动不能把它导回来
        let career = try await rig.services.store.projects()[0]
        try await rig.services.store.purgeProject(career.id)
        let restarted = rig.relaunch()
        await restarted.importLegacyIfNeeded()
        #expect(try await restarted.store.projects().map(\.name) == ["Flow"])
    }

    @Test func 已有的设置不被旧库覆盖() async throws {
        let legacy = try makeLegacyDatabase(settings: ["theme": "\"dark\"", "globalShortcut": "\"Alt+KeyZ\""])
        let rig = TestApp(legacy: legacy)
        rig.services.settings.theme = .light

        await rig.services.importLegacyIfNeeded()

        #expect(rig.services.settings.theme == .light)
    }

    @Test func 没有旧库时什么都不做() async throws {
        let rig = TestApp(legacy: FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).db"))

        await rig.services.importLegacyIfNeeded()

        #expect(rig.services.startupIssues.isEmpty)
        #expect(try await rig.services.store.projects().isEmpty)
    }

    @Test func 旧库损坏时报告问题且下次启动重试() async throws {
        let broken = FileManager.default.temporaryDirectory.appending(path: "broken-\(UUID().uuidString).db")
        try Data("not a database".utf8).write(to: broken)
        let rig = TestApp(legacy: broken)

        await rig.services.importLegacyIfNeeded()
        #expect(rig.services.startupIssues.count == 1)

        try FileManager.default.removeItem(at: broken)
        _ = try makeLegacyDatabase(at: broken)
        let restarted = rig.relaunch()
        await restarted.importLegacyIfNeeded()
        #expect(try await restarted.store.projects().count == 2)
    }
}

@MainActor
struct GlobalShortcutTests {
    @Test(arguments: [
        ("Alt+Space", Shortcut(keyCode: 49, modifiers: .option)),
        ("Control+Alt+Shift+Super+KeyK", Shortcut(keyCode: 40, modifiers: [.control, .option, .shift, .command])),
        ("Super+ArrowUp", Shortcut(keyCode: 126, modifiers: .command)),
        ("Control+F1", Shortcut(keyCode: 122, modifiers: .control)),
        ("Shift+Digit1", Shortcut(keyCode: 18, modifiers: .shift)),
    ])
    func 旧版加速键字符串与快捷键互转(accelerator: String, shortcut: Shortcut) {
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

        let id = try rig.services.images.store(png)

        #expect(id.count == 64)
        #expect(try rig.services.images.store(png) == id)
        #expect(try rig.services.store.files.original(hash: id) == png)
        let url = try #require(rig.services.images.fileURL(for: id))
        #expect(try Data(contentsOf: url) == png)
        #expect(rig.services.images.fileURL(for: String(repeating: "0", count: 64)) == nil)

        let file = rig.directory.appending(path: "dropped.png")
        let other = pngData(shade: 0.9)
        try other.write(to: file)
        let droppedID = try rig.services.images.store(fileAt: file)
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
            continuation.yield(.backfillFinished)
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

    @Test func 缺扩展时征求同意_拒绝后不再提示_同意后安装() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let manager = rig.services.piExtension

        await manager.refresh()
        #expect(manager.needsConsent)

        manager.decline()
        #expect(!manager.needsConsent)

        try await manager.install()
        #expect(manager.status?.file == .current)
        #expect(FileManager.default.fileExists(atPath: rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts").path))
    }

    @Test func Pi_版本过低或不存在时不征求同意() async throws {
        let tooOld = try rigWithPi(version: "0.80.0")
        await tooOld.services.piExtension.refresh()
        #expect(!tooOld.services.piExtension.needsConsent)

        let absent = TestApp()
        await absent.services.piExtension.refresh()
        #expect(!absent.services.piExtension.needsConsent)
    }
}
#endif
