import CueStore
import CoreGraphics
import CueSync
import Foundation
import Synchronization
import ImageIO
import UniformTypeIdentifiers
@testable import CuePad
#if os(iOS)
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

#if os(macOS)
typealias TestApp = Rig
#else
/// iOS 上的一次"App 启动"：临时库目录 + 独立偏好 + 私有命名剪贴板（不与 Mac 同步剪贴板）。
final class TestApp {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sync = FakeSync()
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    private(set) var services: AppServices!

    init() { services = makeServices() }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UIPasteboard.remove(withName: pasteboardName)
    }

    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    @discardableResult
    func relaunch() -> AppServices {
        services.cancelBackgroundWork()
        services = makeServices()
        return services
    }

    private func makeServices() -> AppServices {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = try! LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
        let sync = self.sync
        return AppServices(location: location, defaults: location.makeDefaults(), sync: { _ in sync }, pasteboard: pasteboard)
    }
}
#endif
