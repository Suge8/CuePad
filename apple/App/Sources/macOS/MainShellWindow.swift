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

    func show() {
        unpark()
        if isMiniaturized { deminiaturize(nil) }
        DebugHooks.present(self, activating: true)
    }

    /// 连应用一起隐藏，焦点才会回到此前的前台应用。
    func hide() {
        orderOut(nil)
        NSApp.hide(nil)
        park()
    }

    /// 窗口开着而没人看得到它——不露在屏上（锁屏、屏幕睡着、被整个盖住），人也不在跟前（`AppServices.away`）——时摘下内容，
    /// 有人看得到之前挂回。只盖住而人在用别的 App 时不摘：挪开盖着的窗口那一刻要立刻有内容，挂回后的第一次排版会晚一帧露出空窗。
    /// 人回来的第一下输入（或解锁）就挂回，那时窗口多半还在锁屏或别的窗口后面。脚本起的实例窗口排在最后，不摘（同 `CueViewing`）。
    func parkWhileUnseen(_ services: AppServices) async {
        guard !DebugHooks.scripted else { return }
        for await unseen in Observations({ !services.mainWindowExposed && services.away }) where isVisible {
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
