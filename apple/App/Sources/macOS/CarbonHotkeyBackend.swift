#if os(macOS)
import Carbon.HIToolbox

final class CarbonHotkeyBackend: HotkeyBackend {
    private static let signature: OSType = 0x4355_4550 // 'CUEP'

    private struct Entry {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var entries: [HotkeyHandle: Entry] = [:]
    private var nextHandle: HotkeyHandle = 1
    private var eventHandler: EventHandlerRef?

    /// 事件处理器拿的是未持有的 self 指针：释放前必须先摘掉，系统不会再回调到已释放的对象。
    isolated deinit {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws -> HotkeyHandle {
        try installEventHandlerIfNeeded()
        let handle = nextHandle
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.carbonMask,
            EventHotKeyID(signature: Self.signature, id: handle),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw status == OSStatus(eventHotKeyExistsErr) ? HotkeyError.occupied(shortcut) : .system(status)
        }
        nextHandle += 1
        entries[handle] = Entry(ref: ref, handler: handler)
        return handle
    }

    func unregister(_ handle: HotkeyHandle) {
        guard let entry = entries.removeValue(forKey: handle) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    fileprivate func fire(_ handle: HotkeyHandle) {
        entries[handle]?.handler()
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyPressed,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { throw HotkeyError.system(status) }
    }
}

private extension Shortcut.Modifiers {
    var carbonMask: UInt32 {
        var mask = 0
        if contains(.command) { mask |= cmdKey }
        if contains(.option) { mask |= optionKey }
        if contains(.control) { mask |= controlKey }
        if contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }
}

// Carbon 回调在主线程的应用事件目标上同步派发。
private nonisolated func hotkeyPressed(
    _: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    let backend = Unmanaged<CarbonHotkeyBackend>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { backend.fire(id.id) }
    return noErr
}
#endif
