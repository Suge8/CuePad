#if os(macOS)
import Testing
@testable import CuePad

@MainActor
private final class FakeWindow: ShellWindow {
    var isVisible: Bool
    var isFocused: Bool
    private(set) var shown = 0

    init(isVisible: Bool, isFocused: Bool) {
        self.isVisible = isVisible
        self.isFocused = isFocused
    }

    func show() { shown += 1; isVisible = true; isFocused = true }
    func hide() { isVisible = false; isFocused = false }
}

@MainActor
struct WindowShellTests {
    @Test(arguments: [
        (visible: false, focused: false, hides: false),
        (visible: true, focused: false, hides: false),
        (visible: true, focused: true, hides: true),
    ])
    func 热键仅在窗口可见且聚焦时隐藏(visible: Bool, focused: Bool, hides: Bool) {
        let window = FakeWindow(isVisible: visible, isFocused: focused)
        WindowShell(window: window).toggleFromHotkey()
        #expect(window.isVisible == !hides)
        #expect(window.isFocused == !hides)
    }

    @Test(arguments: [(visible: true, focused: false), (visible: true, focused: true)])
    func 菜单栏在窗口可见时隐藏(visible: Bool, focused: Bool) {
        let window = FakeWindow(isVisible: visible, isFocused: focused)
        WindowShell(window: window).toggleFromMenu()
        #expect(!window.isVisible)
    }

    @Test func 菜单栏在窗口隐藏时显示() {
        let window = FakeWindow(isVisible: false, isFocused: false)
        WindowShell(window: window).toggleFromMenu()
        #expect(window.isVisible && window.shown == 1)
    }

    @Test func 关闭窗口只隐藏不销毁() {
        let window = FakeWindow(isVisible: true, isFocused: true)
        let allowsClose = WindowShell(window: window).windowShouldClose()
        #expect(!allowsClose)
        #expect(!window.isVisible)
    }
}
#endif
