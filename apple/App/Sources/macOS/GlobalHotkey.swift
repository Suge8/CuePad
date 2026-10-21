#if os(macOS)
import Foundation
import Observation

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

/// 一个全局快捷键（一处功能一个）：加速键（W3C code 形式，如 `Alt+Space`）存在设备偏好的 `key` 下，没存过用 `defaultAccelerator`。
/// `set` 换键时先注册新的，成功才释放旧的、写进偏好；失败时抛出，旧的继续生效、偏好不变。设置页的录键直接绑这里。
@Observable
final class GlobalHotkey {
    /// 设置页与启动问题里怎么称呼它
    let label: String
    private(set) var accelerator: String
    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: any HotkeyBackend
    @ObservationIgnored private let onTrigger: @MainActor () -> Void
    @ObservationIgnored private var current: (shortcut: Shortcut, handle: HotkeyHandle)?

    init(
        label: String, key: String, defaultAccelerator: String, defaults: UserDefaults, backend: any HotkeyBackend,
        onTrigger: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.key = key
        self.defaults = defaults
        self.backend = backend
        self.onTrigger = onTrigger
        accelerator = defaults.string(forKey: key) ?? defaultAccelerator
    }

    func registerSaved() throws {
        try register(accelerator)
    }

    func set(_ accelerator: String) throws {
        let normalized = try register(accelerator)
        self.accelerator = normalized
        defaults.set(normalized, forKey: key)
    }

    func unregister() {
        guard let current else { return }
        backend.unregister(current.handle)
        self.current = nil
    }

    /// 注册成功返回规范写法。
    @discardableResult
    private func register(_ accelerator: String) throws -> String {
        guard let shortcut = Shortcut(accelerator: accelerator), let normalized = shortcut.accelerator else {
            throw HotkeyError.unsupportedAccelerator(accelerator)
        }
        guard shortcut != current?.shortcut else { return normalized }
        let handle = try backend.register(shortcut, handler: onTrigger)
        if let current { backend.unregister(current.handle) }
        current = (shortcut, handle)
        return normalized
    }
}
#endif
