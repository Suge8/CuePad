#if os(macOS)
import Foundation

nonisolated struct Shortcut: Hashable, Sendable {
    nonisolated struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// 虚拟键码（kVK_*），与键盘布局无关。
    var keyCode: UInt32
    var modifiers: Modifiers
}

nonisolated enum HotkeyError: Error, Equatable {
    case occupied(Shortcut)
    case unsupportedAccelerator(String)
    case system(Int32)
}

typealias HotkeyHandle = UInt32

/// 系统全局热键接缝：真实实现是 Carbon `RegisterEventHotKey`，测试用内存替身。
protocol HotkeyBackend: AnyObject {
    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws -> HotkeyHandle
    func unregister(_ handle: HotkeyHandle)
}

/// 单槽全局快捷键：更换时先注册新的，成功才释放旧的，失败则旧的继续生效。
final class GlobalHotkey {
    private let backend: any HotkeyBackend
    private let onTrigger: @MainActor () -> Void
    private var current: (shortcut: Shortcut, handle: HotkeyHandle)?

    var shortcut: Shortcut? { current?.shortcut }

    init(backend: any HotkeyBackend, onTrigger: @escaping @MainActor () -> Void) {
        self.backend = backend
        self.onTrigger = onTrigger
    }

    func register(_ shortcut: Shortcut) throws {
        guard shortcut != current?.shortcut else { return }
        let handle = try backend.register(shortcut, handler: onTrigger)
        if let current { backend.unregister(current.handle) }
        current = (shortcut, handle)
    }

    func unregister() {
        guard let current else { return }
        backend.unregister(current.handle)
        self.current = nil
    }
}
#endif
