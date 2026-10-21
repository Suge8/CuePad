#if os(macOS) && DEBUG
import AppKit

/// 画面就绪后在本 App 自己的主窗口里按顺序点几下（截菜单、录任务气泡的开合与换条用；`xc.sh run mac` 起实例后从外面按窗口截、录）。
/// - `-CuePadClick x,y[;x,y|esc|return…]`：左键点；几下之间用分号隔开，隔 `-CuePadClickGap` 秒（默认 1.5），`esc`、`return` 是按一下那个键。
/// - `-CuePadRightClick x,y`：右键点，弹出那里的右键菜单。
/// 事件进事件队列（同真点）：窗口的本地事件监听（浮层的关法、任务气泡的落点）照样看得到。
/// 后台 App 的菜单整份画成停用的灰：要占前台，配 `-CuePadForeground YES`（`DebugForeground`，退出时还回去）。坐标是主窗口里的点，左上为原点。只给本进程的窗口发合成事件，不碰别的应用。菜单开着时主线程在菜单的事件循环里，截完由外面结束实例。
extension DebugScene {
    static func openMenuIfAsked() async {
        let clicks: [(String, NSEvent.EventType, NSEvent.EventType)] = [
            ("CuePadClick", .leftMouseDown, .leftMouseUp), ("CuePadRightClick", .rightMouseDown, .rightMouseUp),
        ]
        guard let (key, down, up) = clicks.first(where: { defaults.string(forKey: $0.0) != nil }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.styleMask.contains(.resizable) })
        else { return }
        let steps = defaults.string(forKey: key)!.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let gap = seconds("CuePadClickGap", default: 1.5)
        DebugForeground.require(window, for: key)
        try? await Task.sleep(for: .milliseconds(500))
        for (index, step) in steps.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(gap)) }
            if let key = keys[step] {
                post(.keyDown, in: window, key: key)
                post(.keyUp, in: window, key: key)
                continue
            }
            let parts = step.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
            for type in [down, up] {
                // 按下与松开同一刻进队列时，滚动视图里的点按手势认不出（按钮不受影响）；同真点隔一小会儿
                if type == up { try? await Task.sleep(for: pressHold) }
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static let pressHold: Duration = .milliseconds(90)

    /// 能按的键：名字、键码与字符。
    private static let keys: [String: (code: UInt16, character: String)] = ["esc": (53, "\u{1b}"), "return": (36, "\r")]

    private static func post(_ type: NSEvent.EventType, in window: NSWindow, key: (code: UInt16, character: String)) {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.character, charactersIgnoringModifiers: key.character,
            isARepeat: false, keyCode: key.code)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
