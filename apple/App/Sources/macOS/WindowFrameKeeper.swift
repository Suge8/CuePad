#if os(macOS)
import AppKit

/// 窗口位置与大小的记忆：存进 `AppSettings` 的偏好存储，而不是系统的窗口自动保存（它总是写标准偏好域，
/// 隔离模式下会串到真实设置里）。
final class WindowFrameKeeper {
    private let window: NSWindow
    private let name: String
    private let settings: AppSettings
    private var following: [Task<Void, Never>] = []

    init(window: NSWindow, name: String, settings: AppSettings) {
        self.window = window
        self.name = name
        self.settings = settings
        following = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name, object: window) { self?.save() }
            }
        }
    }

    isolated deinit {
        following.forEach { $0.cancel() }
    }

    /// 恢复上次的位置；没有存过返回 false。
    func restore() -> Bool {
        guard let descriptor = settings.windowFrame(for: name) else { return false }
        window.setFrame(from: descriptor)
        return true
    }

    private func save() {
        settings.setWindowFrame(window.frameDescriptor, for: name)
    }
}
#endif
