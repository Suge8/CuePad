import CueStore
import CoreGraphics
import CueSync
import Foundation
import Synchronization
import ImageIO
import UniformTypeIdentifiers
@testable import CuePad
#if os(macOS)
import CuePi
#else
import UIKit
#endif

/// 没有事件可订阅的系统异步（弹窗结束、布局后改尺寸、后台任务落盘）：有界条件等待。
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

/// 纯色 4×4 PNG；`shade` 不同则字节不同。
func pngData(shade: CGFloat = 0.5) -> Data {
    let context = CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: shade, green: 0.2, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// 临时目录里的独立偏好存储，释放时连目录一起删除。
final class TempDefaults {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-defaults-\(UUID().uuidString)", directoryHint: .isDirectory)
    let defaults: UserDefaults

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: directory.appending(path: "preferences").path)!
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 记录调用的同步引擎替身；`emit` 推一个状态快照给订阅者。
final class FakeSync: SyncControlling, Sendable {
    private struct State {
        var started = 0
        var stopped = 0
        var syncNows = 0
        var resolutions: [String] = []
    }

    private let state = Mutex(State())
    private let updates: AsyncStream<SyncState>
    private let continuation: AsyncStream<SyncState>.Continuation
    let startError = Mutex<(any Error)?>(nil)

    init() { (updates, continuation) = AsyncStream.makeStream() }

    var started: Int { state.withLock { $0.started } }
    var stopped: Int { state.withLock { $0.stopped } }
    var syncNows: Int { state.withLock { $0.syncNows } }
    var resolutions: [String] { state.withLock { $0.resolutions } }

    var stateUpdates: AsyncStream<SyncState> { updates }

    func emit(_ state: SyncState) { continuation.yield(state) }

    func start() async throws {
        state.withLock { $0.started += 1 }
        if let error = startError.withLock({ $0 }) { throw error }
    }

    func stop() async { state.withLock { $0.stopped += 1 } }
    func syncNow() async throws { state.withLock { $0.syncNows += 1 } }

    func resolve(_ resolution: SyncResolution) async throws {
        state.withLock { $0.resolutions.append("\(resolution)") }
    }
}

/// 一次"App 启动"：临时库目录 + 独立偏好 + 替身（macOS 的发送通道、热键、窗口；iOS 的私有命名剪贴板，
/// 模拟器的通用剪贴板会与 Mac 同步）。`relaunch()` 用同一批目录与偏好再起一个实例。
final class TestApp {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let preferences = TempDefaults()
    let sync = FakeSync()
    #if os(macOS)
    static let hostID = "mac-test"
    let channels = FakeChannels()
    let updater = FakeUpdater()
    let wakeCenter = NotificationCenter()
    let hotkeys = InMemoryHotkeys()
    let window = RecordingWindow()
    let legacy: URL?
    #else
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    #endif
    private(set) var services: AppServices!

    #if os(macOS)
    init(legacy: URL? = nil) {
        self.legacy = legacy
        services = makeServices()
    }
    #else
    init() { services = makeServices() }
    #endif

    deinit {
        try? FileManager.default.removeItem(at: directory)
        #if os(iOS)
        UIPasteboard.remove(withName: pasteboardName)
        #endif
    }

    @discardableResult
    func relaunch() -> AppServices {
        services.cancelBackgroundWork()
        services = makeServices()
        return services
    }

    private var isolatedLocation: LibraryLocation {
        try! LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
    }

    #if os(macOS)
    var piPaths: PiPaths {
        PiPaths(agentDirectory: directory.appending(path: "pi-agent"), socketDirectory: directory.appending(path: "sock"))
    }

    /// 没有旧库：隔离目录；有旧库：把它挂到"应用支持目录"里 Electron 版的位置（旧库位置只由这条规则决定）。
    private func location() -> LibraryLocation {
        guard let legacy else { return isolatedLocation }
        let support = directory.appending(path: "support", directoryHint: .isDirectory)
        let electron = support.appending(path: "CuePad/cuepad.db")
        try! FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: electron)
        try! FileManager.default.createSymbolicLink(at: electron, withDestinationURL: legacy)
        return try! LibraryLocation.resolve(environment: [:], base: .applicationSupport(support))
    }

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            pi: PiBridge(socketDirectory: piPaths.socketDirectory),
            channels: channels,
            hotkeys: hotkeys,
            paths: piPaths,
            installer: PiExtensionInstaller(paths: piPaths, locator: PiExecutableLocator(searchDirectories: [directory.appending(path: "bin")])),
            terminal: PiTerminalJumper(),
            isAccessibilityTrusted: { true },
            hostID: Self.hostID,
            wakeNotifications: wakeCenter,
            commandLineTool: CommandLineToolInstaller(
                helper: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad"),
                linkDirectory: directory.appending(path: "home/.local/bin"), shellPath: { nil }),
            updater: updater)
        let sync = self.sync
        let services = AppServices(location: location(), defaults: preferences.defaults, sync: { _ in sync }, mac: mac)
        services.windowShell = WindowShell(window: window)
        return services
    }
    #else
    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    private func makeServices() -> AppServices {
        let sync = self.sync
        return AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: { _ in sync }, pasteboard: pasteboard)
    }
    #endif
}
