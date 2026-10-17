#if os(macOS) && DEBUG
import AppKit

/// 截菜单用（`xc.sh run mac` 起实例后从外面按窗口截菜单那扇窗）：画面就绪后在本 App 自己的主窗口里点一下，打开那里的系统菜单。
/// - `-CuePadClick x,y`：左键点（工具栏的项目切换胶囊这类点开是菜单的控件）。
/// - `-CuePadRightClick x,y`：右键点，弹出那里的右键菜单。
/// 会把本实例带到前台。坐标是主窗口里的点，左上为原点。只给本进程的窗口发合成事件，不碰别的应用。菜单开着时主线程在菜单的事件循环里，截完由外面结束实例。
extension DebugScene {
    static func openMenuIfAsked() async {
        let clicks: [(String, NSEvent.EventType, NSEvent.EventType)] = [
            ("CuePadClick", .leftMouseDown, .leftMouseUp), ("CuePadRightClick", .rightMouseDown, .rightMouseUp),
        ]
        guard let (key, down, up) = clicks.first(where: { defaults.string(forKey: $0.0) != nil }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.styleMask.contains(.resizable) })
        else { return }
        let parts = defaults.string(forKey: key)!.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        // 后台 App 的菜单整份画成停用的灰：先到前台（会抢焦点，见 docs/verify.md）
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
        for type in [down, up] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            window.sendEvent(event)
        }
    }
}
#endif
