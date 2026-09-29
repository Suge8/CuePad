#if os(macOS)
import AppKit
import SwiftUI

/// 菜单栏图标下方的弹出面板宿主：承载界面提供的 SwiftUI 视图，自身无边框透明，
/// 材质与形状由内容决定。不激活应用，失去键盘焦点或按 Esc 即收起。
@MainActor
final class MenuBarPanel: NSObject, NSWindowDelegate {
    private static let edgeMargin: CGFloat = 8
    private static let anchorGap: CGFloat = 4
    /// 点击图标会先让面板失焦收起，紧随其后的点击动作据此不再把它弹回来。
    private static let reopenGuard: Duration = .milliseconds(250)

    private let panel: Panel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var lastResign = ContinuousClock.now - reopenGuard

    override init() {
        panel = Panel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func setContent<Content: View>(_ content: Content) {
        host.rootView = AnyView(content)
    }

    /// `anchor` 是菜单栏图标在屏幕坐标里的位置。
    func toggle(below anchor: CGRect) {
        if isVisible {
            hide()
        } else if lastResign.duration(to: .now) > Self.reopenGuard {
            show(below: anchor)
        }
    }

    func show(below anchor: CGRect) {
        panel.setContentSize(host.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, below: anchor, in: visible))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResign = .now
        hide()
    }

    /// 面板在图标正下方居中，并留在屏幕可见区域内。
    static func origin(for size: CGSize, below anchor: CGRect, in visible: CGRect) -> CGPoint {
        let x = min(max(anchor.midX - size.width / 2, visible.minX + edgeMargin), visible.maxX - edgeMargin - size.width)
        let y = max(anchor.minY - anchorGap - size.height, visible.minY + edgeMargin)
        return CGPoint(x: x, y: y)
    }
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
#endif
