#if os(macOS)
import AppKit
import SwiftUI

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

    /// 最高到图标下方到屏幕可见区域底边（留边）那么高，再高的部分由内容自己滚（菜单栏面板里是"在做"那一块，`MenuBarPad`）。
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

    static func maxHeight(below anchor: CGRect, in visible: CGRect) -> CGFloat {
        min(anchor.minY, visible.maxY) - anchorGap - (visible.minY + edgeMargin)
    }

    static func origin(for size: CGSize, below anchor: CGRect, in visible: CGRect) -> CGPoint {
        let x = min(max(anchor.midX - size.width / 2, visible.minX + edgeMargin), visible.maxX - edgeMargin - size.width)
        return CGPoint(x: x, y: min(anchor.minY, visible.maxY) - anchorGap - size.height)
    }
}

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
