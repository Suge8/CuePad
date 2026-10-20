#if os(macOS) && DEBUG
import AppKit

/// 本机构建一律在后台跑（`DebugHooks.staysInBackground`）。非占前台不可的只经这里借：前台才有的合成与动画（`InteractionBench` 量掉帧）、
/// 后台画成停用灰的系统菜单（`openMenuIfAsked`）、经窗口服务器的真实事件与指针（`ChatScrollBench` 的 process、hid）。
/// 只在启动参数给了 `-CuePadForeground YES` 时借得到（什么时候才可以给见 docs/verify.md「占前台」）；借时记下当时的前台应用，
/// 动过指针就记下原位，`giveBack` 时都还回去。量完、被结束都经应用终止流程还（`DebugHooks.willTerminate`）；被 KILL 时系统把前台交给下一个应用，指针不还。
enum DebugForeground {
    private static var lender: NSRunningApplication?
    private static var pointer: CGPoint?

    /// 本 App 到前台、`window` 到最前并接过键盘；没给 `-CuePadForeground YES` 时什么都不做，返回 false。
    static func borrow(_ window: NSWindow) -> Bool {
        guard DebugScene.defaults.bool(forKey: "CuePadForeground") else { return false }
        if lender == nil, let front = NSWorkspace.shared.frontmostApplication, front != .current { lender = front }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// 把真实指针移到 `point`（全局坐标，主屏左上为原点）；第一次移时记下原位，`giveBack` 时放回。只在借到前台后调。
    static func movePointer(to point: CGPoint) {
        if pointer == nil { pointer = CGEvent(source: nil)?.location }
        CGWarpMouseCursorPosition(point)
    }

    /// 还前台与指针：窗口排回最后，借前的前台应用回到前台，动过的指针回原位。没借过时什么都不做。
    static func giveBack() {
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        pointer = nil
        guard let lender else { return }
        self.lender = nil
        NSApp.windows.forEach { $0.orderBack(nil) }
        NSApp.yieldActivation(to: lender)
        lender.activate(from: .current)
    }
}
#endif
