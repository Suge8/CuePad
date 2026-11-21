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

    var keyCode: UInt32
    var modifiers: Modifiers
}

nonisolated enum HotkeyError: Error, Equatable {
    case occupied(Shortcut)
    case taken(String)
    case unsupportedAccelerator(String)
    case system(Int32)
}

typealias HotkeyHandle = UInt32

protocol HotkeyBackend: AnyObject {
    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws -> HotkeyHandle
    func unregister(_ handle: HotkeyHandle)
}

@Observable
final class GlobalHotkey {
    let label: String
    private(set) var accelerator: String
    @ObservationIgnored private let slot: HotkeySlot
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let backend: any HotkeyBackend
    @ObservationIgnored private let onTrigger: @MainActor () -> Void
    @ObservationIgnored private var current: (shortcut: Shortcut, handle: HotkeyHandle)?

    init(
        label: String, slot: HotkeySlot, settings: AppSettings, backend: any HotkeyBackend, onTrigger: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.slot = slot
        self.settings = settings
        self.backend = backend
        self.onTrigger = onTrigger
        accelerator = settings.accelerator(slot)
    }

    func registerSaved() throws {
        try register(accelerator)
    }

    func set(_ accelerator: String) throws {
        let normalized = try register(accelerator)
        self.accelerator = normalized
        settings.setAccelerator(normalized, for: slot)
    }

    func unregister() {
        guard let current else { return }
        backend.unregister(current.handle)
        self.current = nil
    }

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
