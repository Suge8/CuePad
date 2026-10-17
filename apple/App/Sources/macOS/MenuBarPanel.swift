#if os(macOS)
import AppKit
import SwiftUI

/// 菜单栏图标下方的弹出面板宿主：承载界面提供的 SwiftUI 视图，自身无边框透明，
/// 材质与形状由内容决定。不激活应用，失去键盘焦点或按 Esc 即收起。
///
/// 收起时内容从面板上摘下：不在窗口里的托管视图不再跟着它读的状态（Cue 的现状、在做的会话、额度…）更新，看不见的东西不占主线程；
/// 托管视图本身留着，内容的状态（草稿、展开、焦点）不丢。打开时先挂回去、量尺寸时按此刻的状态排好再上屏，第一帧就是现在的样子
/// （实测收起期间 Cue 变了状态，打开的头几帧与半秒后一致，不从旧样子过渡）。否决了只隐藏托管视图：隐藏的视图照样更新。
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
        panel.delegate = self
        host.onIntrinsicSizeChange = { [weak self] in self?.fitToContent() }
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
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        placement = (anchor, screen?.visibleFrame ?? anchor)
        panel.contentView = host
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 面板跟随内容尺寸，顶边始终留在图标下方；最高到图标下方到屏幕可见区域底边（留边）那么高，再高的部分由内容自己滚
    /// （菜单栏面板里是"在做"那一块，`MenuBarPad`）。
    private func fitToContent() {
        guard let placement else { return }
        var size = host.fittingSize
        size.height = min(size.height, Self.maxHeight(below: placement.anchor, in: placement.visible))
        let origin = Self.origin(for: size, below: placement.anchor, in: placement.visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
    }

    func hide() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResign = .now
        hide()
    }

    /// 面板最高多高：从图标下方到屏幕可见区域的底边，两头留边。
    static func maxHeight(below anchor: CGRect, in visible: CGRect) -> CGFloat {
        min(anchor.minY, visible.maxY) - anchorGap - (visible.minY + edgeMargin)
    }

    /// 面板在图标正下方居中，顶边贴着图标下方（高度已按 `maxHeight` 收住，不会顶出屏幕上沿），左右留在屏幕可见区域内。
    static func origin(for size: CGSize, below anchor: CGRect, in visible: CGRect) -> CGPoint {
        let x = min(max(anchor.midX - size.width / 2, visible.minX + edgeMargin), visible.maxX - edgeMargin - size.width)
        return CGPoint(x: x, y: min(anchor.minY, visible.maxY) - anchorGap - size.height)
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
        (delegate as? MenuBarPanel)?.hide()
    }
}
#endif
