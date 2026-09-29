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
    private let host = SizingHostingView(rootView: AnyView(EmptyView()))
    private var lastResign = ContinuousClock.now - reopenGuard
    /// 面板在屏幕上的锚点（图标位置与所在屏幕的可见区域）：内容尺寸变化时据此重新定位。
    private var placement: (anchor: CGRect, visible: CGRect)?

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
        host.onIntrinsicSizeChange = { [weak self] in self?.fitToContent() }
    }

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

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
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        placement = (anchor, screen?.visibleFrame ?? anchor)
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 面板跟随内容尺寸，顶边始终留在图标下方。
    private func fitToContent() {
        guard let placement else { return }
        let size = host.fittingSize
        let origin = Self.origin(for: size, below: placement.anchor, in: placement.visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
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

/// 内容的固有尺寸变化（SwiftUI 布局结果）时通知面板调整窗口。
private final class SizingHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
#endif
