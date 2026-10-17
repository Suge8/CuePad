#if os(macOS)
import AppKit

/// 主窗口与它的显隐规则：窗口只隐藏不销毁（关闭钮也是隐藏，自己当自己的代理），真正退出由应用终止流程负责。
/// 隐藏时内容（SwiftUI 的托管控制器）从窗口上摘下——不在窗口里的托管视图不跟着它读的状态更新，
/// 窗口关着时 Cue 被叫醒、会话变化都不占主线程（订阅在 App 级的 `Workspace.follow`，不随窗口，两个面板照常）；
/// 托管控制器留着，页面的状态（滚动位置、展开、草稿）不丢。显示前挂回、按原来的位置与尺寸摆好再上屏。
/// 只在这里收起时摘：缩进程序坞与 ⌘H 系统会再把窗口原样摆回来，不经 `show`。
class MainShellWindow: NSWindow, NSWindowDelegate {
    private var parked: NSViewController?

    func show() {
        if let parked {
            let frame = frame
            contentViewController = parked
            setFrame(frame, display: false)  // 换内容控制器会按内容改窗口尺寸
            self.parked = nil
        }
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// 连应用一起隐藏，焦点才会回到此前的前台应用。
    func hide() {
        orderOut(nil)
        NSApp.hide(nil)
        guard parked == nil, let content = contentViewController else { return }
        let frame = frame
        parked = content
        contentViewController = nil
        setFrame(frame, display: false)
    }

    /// 全局热键：窗口在前台才隐藏；可见但被遮挡时先拉到前台。
    func toggleFromHotkey() {
        if isVisible && isKeyWindow { hide() } else { show() }
    }

    func toggleFromMenu() {
        if isVisible { hide() } else { show() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
#endif
