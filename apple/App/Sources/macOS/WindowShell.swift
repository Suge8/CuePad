#if os(macOS)
import AppKit

protocol ShellWindow: AnyObject {
    var isVisible: Bool { get }
    var isFocused: Bool { get }
    func show()
    func hide()
}

/// 主窗口的显隐规则。窗口只隐藏不销毁，真正退出由应用终止流程负责。
final class WindowShell {
    private let window: any ShellWindow

    init(window: any ShellWindow) {
        self.window = window
    }

    /// 主窗口在屏幕上（没隐藏、没缩进程序坞）。
    var isVisible: Bool { window.isVisible }

    func show() {
        window.show()
    }

    func hide() {
        window.hide()
    }

    /// 全局热键：窗口在前台才隐藏；可见但被遮挡时先拉到前台。
    func toggleFromHotkey() {
        if window.isVisible && window.isFocused { window.hide() } else { window.show() }
    }

    func toggleFromMenu() {
        if window.isVisible { window.hide() } else { window.show() }
    }

    func windowShouldClose() -> Bool {
        window.hide()
        return false
    }
}

/// 主窗口（`WindowShell` 管它的显隐）：隐藏时内容（SwiftUI 的托管控制器）从窗口上摘下——不在窗口里的托管视图不跟着它读的状态更新，
/// 窗口关着时 Cue 被叫醒、会话变化都不占主线程（订阅在 App 级的 `Workspace.follow`，不随窗口，两个面板照常）；
/// 托管控制器留着，页面的状态（滚动位置、展开、草稿）不丢。显示前挂回、按原来的位置与尺寸摆好再上屏。
/// 只在这里收起时摘：缩进程序坞与 ⌘H 系统会再把窗口原样摆回来，不经 `show`。
class MainShellWindow: NSWindow, ShellWindow {
    private var parked: NSViewController?

    var isFocused: Bool { isKeyWindow }

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
}

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    private let shell: WindowShell

    init(shell: WindowShell) {
        self.shell = shell
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shell.windowShouldClose()
    }
}
#endif
