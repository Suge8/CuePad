#if os(macOS) && DEBUG
import AppKit

/// 画面就绪后在本 App 自己的主窗口里按顺序点几下（截菜单、录任务气泡的开合与换条用；`xc.sh run mac` 起实例后从外面按窗口截、录）。
/// - `-CuePadClick x,y[;x,y|esc|return|type:文字…]`：左键点；几下之间用分号隔开，隔 `-CuePadClickGap` 秒（默认 1.5），`esc`、`return` 是按一下那个键，
///   `type:文字` 是往窗口此刻的焦点里打进这几个字（按键事件只发给激活的窗口，后台窗口里看点进输入框落在哪靠它），
///   `cmd:键` 是按主菜单的快捷键 ⌘键（如 `cmd:f` 打开全屏页里 PDF 的查找条）。
/// - `-CuePadRightClick x,y`：右键点，弹出那里的右键菜单。
/// - 双击、拖、捏合、智能缩放、双指滑动与方向键几步见 `DebugGestures+Mac.swift`。
/// 事件进事件队列（同真点）：窗口的本地事件监听（浮层的关法、任务气泡的落点）照样看得到。
/// 事件只在本进程里合成、不经窗口服务器，后台的窗口照样按点处理（不先"激活"），点开浮层、气泡、按钮看逻辑与摆位不占前台；截出来是未激活窗口的样子。
/// 系统菜单在后台 App 里整份画成停用的灰：右键点必须占前台（`-CuePadForeground YES`，`DebugForeground`，退出时还回去），左键点开的是系统菜单时也加它。坐标是主窗口里的点，左上为原点。只给本进程的窗口发合成事件，不碰别的应用。菜单开着时主线程在菜单的事件循环里，截完由外面结束实例。
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
        if down == .rightMouseDown { DebugForeground.require(window, for: key) } else { _ = DebugForeground.borrow(window) }
        try? await Task.sleep(for: .milliseconds(500))
        for (index, step) in steps.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(gap)) }
            if step.hasPrefix("type:") {
                (window.firstResponder as? any NSTextInputClient)?.insertText(String(step.dropFirst(5)), replacementRange: NSRange(location: NSNotFound, length: 0))
                continue
            }
            if await gesture(step, in: window) { continue }
            if let key = keys[step] {
                post(.keyDown, in: window, key: key)
                post(.keyUp, in: window, key: key)
                continue
            }
            if step.hasPrefix("cmd:") {
                perform(menuKey: String(step.dropFirst(4)), in: window)
                continue
            }
            let parts = step.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
            // 后台窗口的第一下只用来激活，文字区不接、也不拿焦点：照激活的窗口里真点的样子，先交焦点，再交给它自己的按下处理（它在里面等松开）
            if !window.isKeyWindow, down == .leftMouseDown, let text = window.contentView?.superview?.hitTest(point) as? NSTextView {
                guard let press = mouse(down, at: point, in: window), let release = mouse(up, at: point, in: window) else { return }
                window.makeFirstResponder(text)
                NSApp.postEvent(release, atStart: false)
                text.mouseDown(with: press)
                continue
            }
            for type in [down, up] {
                // 按下与松开同一刻进队列时，滚动视图里的点按手势认不出（按钮不受影响）；同真点隔一小会儿
                if type == up { try? await Task.sleep(for: pressHold) }
                guard let event = mouse(type, at: point, in: window) else { return }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static let pressHold: Duration = .milliseconds(90)

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static let keys: [String: (code: UInt16, character: String)] = ["esc": (53, "\u{1b}"), "return": (36, "\r")]

    /// `cmd:键`：主菜单里快捷键是 ⌘键 的那一项，从窗口此刻的焦点沿响应链发它的动作（同按下 ⌘键）。
    /// 后台窗口不是 key，菜单的快捷键与校验都找不到接收者，所以不经菜单分派，直接从焦点沿响应链发。
    private static func perform(menuKey key: String, in window: NSWindow) {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            menu.items.lazy.compactMap { item in
                item.keyEquivalent == key && item.keyEquivalentModifierMask == .command ? item : item.submenu.flatMap(find)
            }.first
        }
        guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else { return }
        _ = window.firstResponder?.tryToPerform(action, with: item)
    }

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
