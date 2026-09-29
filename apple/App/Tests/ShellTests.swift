#if os(macOS)
import Testing
@testable import CuePad

@MainActor
private final class FakeHotkeyBackend: HotkeyBackend {
    var occupied: Set<Shortcut> = []
    private var handles: [HotkeyHandle: (shortcut: Shortcut, handler: @MainActor () -> Void)] = [:]
    private var nextHandle: HotkeyHandle = 1

    var active: Set<Shortcut> { Set(handles.values.map(\.shortcut)) }

    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws -> HotkeyHandle {
        guard !occupied.contains(shortcut), !active.contains(shortcut) else {
            throw HotkeyError.occupied(shortcut)
        }
        defer { nextHandle += 1 }
        handles[nextHandle] = (shortcut, handler)
        return nextHandle
    }

    func unregister(_ handle: HotkeyHandle) { handles[handle] = nil }

    func press(_ shortcut: Shortcut) {
        handles.values.filter { $0.shortcut == shortcut }.forEach { $0.handler() }
    }
}

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
struct GlobalHotkeyTests {
    private let other = Shortcut(keyCode: 40, modifiers: [.control, .option])
    private let taken = Shortcut(keyCode: 41, modifiers: [.command, .shift])

    @Test func 注册后按键触发回调_注销后释放() throws {
        let backend = FakeHotkeyBackend()
        var triggered = 0
        let hotkey = GlobalHotkey(backend: backend) { triggered += 1 }

        try hotkey.register(.optionSpace)
        backend.press(.optionSpace)
        #expect(triggered == 1)
        #expect(hotkey.shortcut == .optionSpace)

        hotkey.unregister()
        #expect(backend.active.isEmpty)
        #expect(hotkey.shortcut == nil)
    }

    @Test func 更换快捷键成功后释放旧的() throws {
        let backend = FakeHotkeyBackend()
        let hotkey = GlobalHotkey(backend: backend) {}
        try hotkey.register(.optionSpace)

        try hotkey.register(other)

        #expect(backend.active == [other])
        #expect(hotkey.shortcut == other)
    }

    @Test func 更换失败时回滚_旧快捷键继续生效() throws {
        let backend = FakeHotkeyBackend()
        backend.occupied = [taken]
        var triggered = 0
        let hotkey = GlobalHotkey(backend: backend) { triggered += 1 }
        try hotkey.register(.optionSpace)

        #expect(throws: HotkeyError.occupied(taken)) { try hotkey.register(taken) }

        #expect(hotkey.shortcut == .optionSpace)
        backend.press(.optionSpace)
        #expect(triggered == 1)
    }

    @Test func 首次注册被占用时抛错且无残留() {
        let backend = FakeHotkeyBackend()
        backend.occupied = [.optionSpace]
        let hotkey = GlobalHotkey(backend: backend) {}

        #expect(throws: HotkeyError.occupied(.optionSpace)) { try hotkey.register(.optionSpace) }
        #expect(hotkey.shortcut == nil)
    }
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
