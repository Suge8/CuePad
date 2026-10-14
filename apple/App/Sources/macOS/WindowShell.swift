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

extension NSWindow: ShellWindow {
    var isFocused: Bool { isKeyWindow }

    func show() {
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// 连应用一起隐藏，焦点才会回到此前的前台应用。
    func hide() {
        orderOut(nil)
        NSApp.hide(nil)
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
