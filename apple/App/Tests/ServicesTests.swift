#if os(macOS)
import struct CueStore.PiSession
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
        let resumed = try PiHistory.index(file: file, from: checkpoint, files: rig.services.store.files)
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
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, files: rig.services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }

        await rig.services.consumePiHistory(events)

        #expect(try await rig.services.store.piSessions().map(\.id) == ["sess-1"])
    }
}

/// 接入 Pi：扩展、技能与 cuepad 命令行链接三样一起写、一起删（全在 TestApp 的临时目录里，不碰真实 ~/.pi 与 ~/.local/bin）。
/// 测试走的是设置开关与侧栏询问卡调用的同一组接口（`PiIntegrationManager`）。
struct PiConnectTests {
    private func rigWithPi(version: String) throws -> TestApp {
        let rig = TestApp()
        let bin = rig.directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appending(path: "pi")
        try "#!/bin/sh\necho \(version)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return rig
    }

    private struct Files {
        let bridgeExtension, skill, link: URL
        init(_ rig: TestApp) {
            bridgeExtension = rig.piPaths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
            skill = rig.piPaths.skillsDirectory.appending(path: "cuepad/SKILL.md")
            link = rig.piPaths.binDirectory.appending(path: "cuepad")
        }
        var all: [URL] { [bridgeExtension, skill, link] }
    }

    /// 不跟随链接：失效的链接也算在。
    private func exists(_ file: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil }

    /// 测试宿主就是这次构建出的 CuePad.app，里面真的带着 cuepad。
    private var realHelper: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad") }

    private func runHelp(_ rig: TestApp, via link: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = link
        process.arguments = ["--help"]
        process.environment = ["CUEPAD_LIBRARY_DIR": rig.directory.appending(path: "cli-library").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func 接入后三样都在且cuepad可执行_移除后三样都没了() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        rig.helper = realHelper
        let services = rig.relaunch()
        let manager = services.piIntegration, files = Files(rig)

        try await manager.connect()

        #expect(try String(contentsOf: files.bridgeExtension, encoding: .utf8) == PiExtensionBundle.source)
        #expect(try String(contentsOf: files.skill, encoding: .utf8).contains("\(files.link.path) show <文件>"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: files.link.path) == realHelper.path)
        let help = try runHelp(rig, via: files.link)
        #expect(help.status == 0 && help.output.contains("cuepad"))
        #expect(manager.status?.isCurrent == true)

        try await manager.disconnect()

        for file in files.all { #expect(!exists(file), "\(file.path) 应已删除") }
        #expect(!exists(files.skill.deletingLastPathComponent()))  // 技能目录是 CuePad 建的，空了一起删
        try await rig.relaunch().piIntegration.refresh()  // 移除算拒绝过：再启动也不问、不补
        #expect(!rig.services.piIntegration.needsConsent)
        for file in files.all { #expect(!exists(file)) }
    }

    @Test func 别人的同名文件不动_接入整体拒绝_移除只删自己的() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let manager = rig.services.piIntegration, files = Files(rig)
        let mine = "我自己的东西\n"
        // 别的 App 包里同样位置的 cuepad（包在、标识不是 CuePad），与已不存在的、不叫 CuePad.app 的包
        let other = rig.directory.appending(path: "Other.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
            .write(to: other.appending(path: "Contents/Info.plist"))
        let occupants: [(URL, () throws -> Void)] = [
            (files.bridgeExtension, { try mine.write(to: files.bridgeExtension, atomically: true, encoding: .utf8) }),
            (files.bridgeExtension, { try Data([0xff, 0xfe, 0x00]).write(to: files.bridgeExtension) }),  // 不是 UTF-8 文本
            (files.skill, { try mine.write(to: files.skill, atomically: true, encoding: .utf8) }),
            (files.skill, { try Data([0xff, 0xfe, 0x00]).write(to: files.skill) }),
            (files.link, { try mine.write(to: files.link, atomically: true, encoding: .utf8) }),
            (files.link, { try FileManager.default.createSymbolicLink(atPath: files.link.path, withDestinationPath: other.path + "/Contents/Helpers/cuepad") }),
            (files.link, { try FileManager.default.createSymbolicLink(atPath: files.link.path, withDestinationPath: "/Volumes/Gone/Other.app/Contents/Helpers/cuepad") }),
        ]
        for (occupied, occupy) in occupants {
            for file in files.all where exists(file) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.createDirectory(at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
            try occupy()
            let before = try FileManager.default.attributesOfItem(atPath: occupied.path)[.modificationDate] as? Date
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: occupied.path)

            await #expect(throws: PiInstallError.occupied([occupied])) { try await manager.connect() }
            try await manager.disconnect()  // 什么都没接入：移除也不能碰它

            #expect(try FileManager.default.attributesOfItem(atPath: occupied.path)[.modificationDate] as? Date == before)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: occupied.path)) == target)
            for file in files.all where file != occupied { #expect(!exists(file), "被占用时 \(file.lastPathComponent) 不该写") }
        }

        for file in files.all where exists(file) { try FileManager.default.removeItem(at: file) }
        try await manager.connect()
        try FileManager.default.removeItem(at: files.skill)
        try mine.write(to: files.skill, atomically: true, encoding: .utf8)  // 接入后用户换成了自己的同名技能

        try await manager.disconnect()

        #expect(try String(contentsOf: files.skill, encoding: .utf8) == mine)
        #expect(!exists(files.bridgeExtension) && !exists(files.link))
    }

    @Test func App移动后启动时静默把链接改指新位置() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let files = Files(rig)
        rig.helper = rig.directory.appending(path: "Old/CuePad.app/Contents/Helpers/cuepad")
        try await rig.relaunch().piIntegration.connect()
        let skill = try String(contentsOf: files.skill, encoding: .utf8)

        rig.helper = realHelper  // App 移动到了测试宿主所在的位置
        try await rig.relaunch().piIntegration.refresh()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: files.link.path) == realHelper.path)
        #expect(try String(contentsOf: files.skill, encoding: .utf8) == skill)
        #expect(try runHelp(rig, via: files.link).status == 0)
        #expect(rig.services.piIntegration.status?.isCurrent == true)
        #expect(!rig.services.piIntegration.needsConsent)
    }

    /// 接入后 Pi 卸了（或降级到不支持的版本）：设置里仍能关掉开关，三样照样删干净。
    @Test func Pi不可用后仍能移除() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        try await rig.services.piIntegration.connect()
        try FileManager.default.removeItem(at: rig.directory.appending(path: "bin/pi"))

        let manager = rig.relaunch().piIntegration
        try await manager.refresh()
        #expect(manager.status?.pi == .notFound)
        #expect(manager.canToggle)

        try await manager.disconnect()
        for file in Files(rig).all { #expect(!exists(file)) }
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

    @Test func 首次询问_拒绝后不再问也什么都不写() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        try await rig.services.piIntegration.refresh()
        #expect(rig.services.piIntegration.needsConsent)

        rig.services.piIntegration.decline()
        try await rig.relaunch().piIntegration.refresh()

        #expect(!rig.services.piIntegration.needsConsent)
        for file in Files(rig).all { #expect(!exists(file)) }
    }

    @Test func Pi_版本过低或不存在时不询问() async throws {
        let tooOld = try rigWithPi(version: "0.80.0")
        try await tooOld.services.piIntegration.refresh()
        #expect(!tooOld.services.piIntegration.needsConsent)

        let absent = TestApp()
        try await absent.services.piIntegration.refresh()
        #expect(!absent.services.piIntegration.needsConsent)
    }

    /// 已接入（扩展是 CuePad 写的）就不再询问：旧版扩展、旧版技能、当初没装的命令行链接，启动检查时一起补成最新。
    @Test func 已装旧版扩展时启动检查静默补齐三样() async throws {
        let rig = try rigWithPi(version: "0.90.0")
        let files = Files(rig)
        try FileManager.default.createDirectory(at: rig.piPaths.extensionsDirectory, withIntermediateDirectories: true)
        let old = PiExtensionBundle.source.replacing(/const EXTENSION_VERSION = \d+;/, with: "const EXTENSION_VERSION = 1;")
        try old.write(to: files.bridgeExtension, atomically: true, encoding: .utf8)

        try await rig.services.piIntegration.refresh()

        #expect(rig.services.piIntegration.status?.isCurrent == true)
        #expect(try String(contentsOf: files.bridgeExtension, encoding: .utf8) == PiExtensionBundle.source)
        #expect(exists(files.skill) && exists(files.link))
        #expect(!rig.services.piIntegration.needsConsent)
    }
}

/// 查本机运行时的登录状态很慢（三家命令各最多 15 秒），只在启用、换运行时与大脑起不来时查。
struct CueRuntimeScanTests {
    @Test func 启动时Cue已在本机值班_不查运行时() async throws {
        let scans = Mutex(0)
        // 大脑一直在起：不走到"起不来"那条会查的路
        let app = TestApp(cue: CueDependencies(
            scan: { scans.withLock { $0 += 1 }; return [] }, launch: { _ in try? await Task.sleep(for: .seconds(2)); return nil },
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
#endif
