#if os(macOS)
import AppKit

/// 应用对象。主窗口挂着弹窗（sheet、警告框）或有应用级模态面板时，系统的 `terminate(_:)` 会拒绝退出
/// （日志 "blocked by modal sheet"，不会走到 `applicationShouldTerminate`）。所以退出前先结束这些弹窗，
/// 等它们真正消失再终止；⌘Q、Dock 退出、SIGTERM 共用这一条路径。
@objc(CuePadApplication)
final class CuePadApplication: NSApplication {
    private var isDismissingForTermination = false

    override func terminate(_ sender: Any?) {
        if modalWindow != nil { abortModal() }
        // 等弹窗结束期间再次退出（比如又按了一次 ⌘Q）：不再等，直接交给系统
        guard !isDismissingForTermination else { return super.terminate(sender) }
        isDismissingForTermination = true
        Self.dismissPresentations(in: windows) { [self] in
            isDismissingForTermination = false
            terminateNow(sender)
        }
    }

    private func terminateNow(_ sender: Any?) {
        super.terminate(sender)
    }

    /// 结束挂在这些窗口上的弹窗（嵌套的一并结束），全部真正结束后调用 `proceed`；没有弹窗则立即调用。
    /// `endSheet` 之后弹窗还要走完收起动画才算结束，靠系统的 didEndSheet 通知判断，而不是固定延时。
    static func dismissPresentations(in windows: [NSWindow], then proceed: @escaping @MainActor () -> Void) {
        let attachments = attachedSheets(in: windows)
        guard !attachments.isEmpty else { return proceed() }
        let waiter = SheetEndWaiter(parents: attachments.map(\.parent), then: proceed)
        for attachment in attachments { attachment.parent.endSheet(attachment.sheet) }
        _ = waiter
    }

    /// 内层弹窗排在前面。
    private static func attachedSheets(in windows: [NSWindow]) -> [(parent: NSWindow, sheet: NSWindow)] {
        windows.flatMap { window -> [(parent: NSWindow, sheet: NSWindow)] in
            guard let sheet = window.attachedSheet else { return [] }
            return attachedSheets(in: [sheet]) + [(window, sheet)]
        }
    }
}

/// 等每个弹窗的宿主窗口各发出一次 didEndSheet。
@MainActor
private final class SheetEndWaiter {
    private var remaining: [ObjectIdentifier]
    private let proceed: @MainActor () -> Void
    private var token: (any NSObjectProtocol)?

    init(parents: [NSWindow], then proceed: @escaping @MainActor () -> Void) {
        remaining = parents.map(ObjectIdentifier.init)
        self.proceed = proceed
        // 先订阅再 endSheet：没有动画时通知可能同步到达
        token = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let parent = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.ended(parent) }
        }
        retained = self // 等待期间自己保持自己，全部结束后释放
    }

    private var retained: SheetEndWaiter?

    private func ended(_ parent: NSWindow) {
        guard let index = remaining.firstIndex(of: ObjectIdentifier(parent)) else { return }
        remaining.remove(at: index)
        guard remaining.isEmpty else { return }
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        retained = nil
        proceed()
    }
}
#endif
