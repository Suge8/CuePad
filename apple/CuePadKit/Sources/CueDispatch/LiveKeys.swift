#if os(macOS)
import ApplicationServices
import CoreGraphics

/// 辅助功能授权：权限归属 CuePad.app 本身。
public enum Accessibility {
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// 未授权时弹出系统授权引导，返回当前是否已授权。
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// CGEvent 定向投递：`postToPid` 只送达目标进程，不经过系统全局事件流。
public struct CGEventKeys: KeyPosting {
    private static let keyV: CGKeyCode = 9
    private static let keyReturn: CGKeyCode = 36

    public init() {}

    public func preflight() throws(DispatchError) {
        _ = try events(.paste)
    }

    public func post(_ key: Keystroke, to pid: pid_t) throws(DispatchError) {
        let (down, up) = try events(key)
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func events(_ key: Keystroke) throws(DispatchError) -> (CGEvent, CGEvent) {
        let code = key == .paste ? Self.keyV : Self.keyReturn
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw .eventCreateFailed }
        if key == .paste {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        return (down, up)
    }
}

extension Dispatcher {
    /// 生产装配：NSWorkspace 追踪 + 通用剪贴板 + CGEvent。
    public static func live(apps: WorkspaceApps, timing: Timing = Timing()) -> Dispatcher {
        Dispatcher(
            apps: apps, clipboard: PasteboardWriter(), keys: CGEventKeys(),
            isTrusted: Accessibility.isTrusted, timing: timing)
    }
}
#endif
