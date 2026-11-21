#if os(macOS)
import AppKit

/// 主窗口与它的显隐规则：窗口只隐藏不销毁（关闭钮也是隐藏，自己当自己的代理），真正退出由应用终止流程负责。
/// 隐藏时内容（SwiftUI 的托管控制器）从窗口上摘下——不在窗口里的托管视图不跟着它读的状态更新，
/// 窗口关着时 Cue 被叫醒、会话变化都不占主线程（订阅在 App 级的 `Workspace.follow`，不随窗口，两个面板照常）；
/// 托管控制器留着，页面的状态（滚动位置、展开、草稿）不丢。显示前挂回、按原来的位置与尺寸摆好再上屏。
/// 收起时摘；缩进程序坞与 ⌘H 系统会再把窗口原样摆回来，不经 `show`。
/// 开着却没人看得到时也摘（`parkWhileUnseen`）：锁屏、屏幕睡着时托管视图照样随每次写入重排，读屏开着（有辅助功能客户端连过）时
/// 每排一次还要给整棵辅助功能树重算文字属性。2026-10-25 对正式版采样：锁屏、停在进展页时，会话状态每写一次（约 15 秒），
/// 主线程就为看板的卡片查约 700 次字体显示名（`AccessibilityViewGraph` → `NSFont.displayName`），与按节奏的拉取抢主线程。
class MainShellWindow: NSWindow, NSWindowDelegate {
    private var parked: NSViewController?
    private(set) var unfilled: NSRect?
    private var restoresAfterFullScreen = false

    /// 铺满所在的屏幕（菜单栏与程序坞之外），`restoreFrame` 放回原来的位置。不用系统的全屏：它另开一个桌面，
    /// 应用换不到前台时（`show(overOthers:)`）系统不一定切过去，远程画面里就还是原来的桌面。系统全屏着的不动。
    func fillScreen() {
        restoresAfterFullScreen = false
        guard !styleMask.contains(.fullScreen), let screen else { return }
        if unfilled == nil { unfilled = frame }
        setFrame(screen.visibleFrame, display: true, animate: true)
    }

    /// 系统全屏着时先记着：这时改不了位置，出全屏时系统又会把窗口摆回进全屏前（铺满）的样子，原来的位置就丢了。
    func restoreFrame() {
        guard let frame = unfilled else { return }
        restoresAfterFullScreen = styleMask.contains(.fullScreen)
        guard !restoresAfterFullScreen else { return }
        unfilled = nil
        setFrame(frame, display: true, animate: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if restoresAfterFullScreen { restoreFrame() }
    }

    /// `overOthers`：不是这台 Mac 上的操作要它出来的（手机请它亮出来，`Workspace.showLive`）。系统不让应用这时把自己换到前台
    /// （实测 macOS 27.2：`NSApp.activate()` 之后前台还是原来那个应用），窗口自己排到所有窗口最前不用换前台：远程画面里一眼看得到，点它一下前台就过来。
    func show(overOthers: Bool = false) {
        unpark()
        if isMiniaturized { deminiaturize(nil) }
        present(activating: true, overOthers: overOthers)
    }

    /// 连应用一起隐藏，焦点才会回到此前的前台应用。
    func hide() {
        orderOut(nil)
        NSApp.hide(nil)
        park()
    }

    func parkWhileUnseen(_ services: AppServices) async {
        guard !DebugHooks.scripted else { return }
        for await unseen in Observations({ services.viewer.unseen }) where isVisible {
            if unseen { park() } else { unpark() }
        }
    }

    private func park() {
        guard parked == nil, let content = contentViewController else { return }
        let frame = frame
        parked = content
        contentViewController = nil
        setFrame(frame, display: false)
    }

    private func unpark() {
        guard let parked else { return }
        let frame = frame
        contentViewController = parked
        setFrame(frame, display: false)  // 换内容控制器会按内容改窗口尺寸
        self.parked = nil
    }

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
extension NSWindow {
    func present(activating: Bool = false, overOthers: Bool = false) {
        guard !DebugHooks.keepsBehind(self) else { return }
        if activating { NSApp.activate() }
        makeKeyAndOrderFront(nil)
        if overOthers { orderFrontRegardless() }
    }
}
#endif
