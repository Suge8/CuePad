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

/// 测试用资料库的临时目录。库会被服务里的后台任务一直持有到它们自己结束，删掉仍打开的库文件时 SQLite 报
/// "database integrity compromised … vnode unlinked while in use"；所以本次运行不删自己的目录，
/// 而是在下次运行开始时清掉已经结束的运行（进程已不在）留下的目录。
enum TestLibraries {
    private static let root = FileManager.default.temporaryDirectory.appending(path: "cuepad-app-test-libraries", directoryHint: .isDirectory)
    private static let run: URL = {
        removeFinishedRuns()
        return root.appending(path: "\(getpid())", directoryHint: .isDirectory)
    }()

    /// 本次运行里一个新的空目录。
    static func makeDirectory() -> URL {
        let directory = run.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeFinishedRuns() {
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in runs {
            guard let pid = Int32(name), kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }
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
nonisolated final class FakeSync: SyncControlling, Sendable {
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

    /// 为 true 时 `stop()` 永不返回（模拟卡住的同步引擎）。
    let stopHangs = Mutex(false)

    func stop() async {
        state.withLock { $0.stopped += 1 }
        if stopHangs.withLock({ $0 }) { try? await Task.sleep(for: .seconds(3600)) }
    }
    func syncNow() async throws { state.withLock { $0.syncNows += 1 } }
    func pullChanges() async throws {}
    func preparePull() async throws {}
    /// 立即上传过的记录名，按调用顺序。
    let uploads = AsyncStream<String>.makeStream()
    func sendNow(recordName: String, deleted: Bool) async throws { uploads.continuation.yield(recordName) }

    func resolve(_ resolution: SyncResolution) async throws {
        state.withLock { $0.resolutions.append("\(resolution)") }
    }
}

/// 一次"App 启动"：临时库目录 + 独立偏好 + 替身（macOS 的发送通道、热键、窗口；iOS 的私有命名剪贴板，
/// 模拟器的通用剪贴板会与 Mac 同步）。`relaunch()` 用同一批目录与偏好再起一个实例。
final class TestApp {
    let directory = TestLibraries.makeDirectory()
    let preferences = TempDefaults()
    let sync = FakeSync()
    #if os(macOS)
    static let hostID = "mac-test"
    let channels = FakeChannels()
    let updater = FakeUpdater()
    let wakeCenter = NotificationCenter()
    let hotkeys = InMemoryHotkeys()
    lazy var host = RecordingHost(channels: channels)
    /// 测试里的 Pi 可执行文件（执行器启动会话时用；不真运行）
    nonisolated static let piExecutable = URL(filePath: "/opt/test/bin/pi")
    let window = RecordingWindow()
    #else
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    #endif
    private(set) var services: AppServices!

    /// 同步引擎的来源；默认用记录型替身 `sync`。
    private let syncSource: AppServices.SyncSource?

    init(sync source: AppServices.SyncSource? = nil) {
        syncSource = source
        services = makeServices()
    }

    #if os(iOS)
    deinit { UIPasteboard.remove(withName: pasteboardName) }
    #endif

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

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            pi: PiBridge(socketDirectory: piPaths.socketDirectory),
            channels: channels,
            hotkeys: hotkeys,
            paths: piPaths,
            installer: PiIntegration(
                paths: piPaths, locator: PiExecutableLocator(searchDirectories: [directory.appending(path: "bin")]),
                cuepad: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad")),
            terminal: PiTerminalJumper(),
            hostID: Self.hostID,
            wakeNotifications: wakeCenter,
            commandLineTool: CommandLineToolInstaller(
                helper: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad"),
                linkDirectory: directory.appending(path: "home/.local/bin"), shellPath: { nil }),
            updater: updater,
            host: host,
            locatePi: { Self.piExecutable })
        let services = try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), mac: mac)
        services.windowShell = WindowShell(window: window)
        return services
    }
    #else
    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    private func makeServices() -> AppServices {
        try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), pasteboard: pasteboard)
    }
    #endif
}

extension CueStore {
    /// 全部会话记录（测试核对用；界面按范围与页读，见 `piSessionPage`）。
    func allPiSessionStates() throws -> [PiSessionState] {
        try piSessionPage(PiSessionQuery(limit: .max)).items.map(\.state)
    }
}
