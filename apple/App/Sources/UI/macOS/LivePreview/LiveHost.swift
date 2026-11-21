#if os(macOS)
import AppKit
import WebKit

/// 没开在面板里、Agent 又在用的预览（`LivePreview.agentActive`），网页视图挂在这个看不见的窗口里：不在任何窗口里的网页 WebKit 当它藏着，
/// requestAnimationFrame、IntersectionObserver、ResizeObserver 都不跑（实测），canvas 画不出、过渡走不完、懒加载出不来，原生点击也没处落。
/// 窗口全透明、不接鼠标、不进窗口菜单与 ⌘` 循环、成不了 key/main、不进截屏共享，排在普通窗口下面、每个桌面都有它；
/// App 隐藏时它不跟着藏（藏了网页又算藏着）。几个后台预览叠在里面，各按自己的大小；空了就收掉。
@MainActor
enum LiveHost {
    private static var window: NSWindow?

    static func park(_ web: WKWebView, size: CGSize) {
        let window = window ?? make()
        web.autoresizingMask = []
        web.frame = CGRect(origin: .zero, size: size)
        window.contentView?.addSubview(web)
        fit(window)
    }

    static func unpark(_ web: WKWebView) {
        guard let window, web.window === window else { return }
        web.removeFromSuperview()
        tidy()
    }

    static func tidy() {
        guard let window, window.contentView?.subviews.isEmpty != false else { return }
        window.orderOut(nil)
        Self.window = nil
    }

    /// 窗口要盖住里面最大的那个视图：露在窗口外的部分网页不画。放在主屏左下角，屏上才有刷新节拍（rAF 跟屏幕走）。
    private static func fit(_ window: NSWindow) {
        let sizes = window.contentView?.subviews.map(\.frame.size) ?? []
        let size = CGSize(width: sizes.map(\.width).max() ?? 1, height: sizes.map(\.height).max() ?? 1)
        let origin = (NSScreen.main ?? NSScreen.screens.first)?.frame.origin ?? .zero
        window.setFrame(CGRect(origin: origin, size: size), display: false)
        for view in window.contentView?.subviews ?? [] { view.setFrameOrigin(CGPoint(x: 0, y: size.height - view.frame.height)) }
    }

    private static func make() -> NSWindow {
        let window = Window(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.canHide = false
        window.sharingType = .none
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.orderBack(nil)
        Self.window = window
        return window
    }

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

final class PageView: WKWebView {
    var leftWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { leftWindow?() }
    }
}
#endif
