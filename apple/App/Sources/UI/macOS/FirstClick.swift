#if os(macOS)
import AppKit

/// 点进没激活的窗口的那一下（首击）：系统按钮不接它，只把窗口激活，那一下落到下面的行上。不用按钮的点按目标（`TaskCompletionRing`）照这个规矩。
/// 判断：按下发生在窗口成为主窗口之前（按下把窗口激活，成为主窗口的时刻晚于按下事件的时间戳；两者同一个时钟，开机以来的秒数）。
enum FirstClick {
    private static var keyAt: TimeInterval = 0

    /// 启动时装一次：之后每次有窗口成为主窗口都记下时刻。
    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            keyAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 正在处理的这次按下是不是首击。
    static var isCurrent: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return false }
        return event.timestamp <= keyAt
    }
}
#endif
