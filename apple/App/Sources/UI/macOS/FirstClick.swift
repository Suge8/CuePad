#if os(macOS)
import AppKit
import SwiftUI

/// 点进没激活的窗口的那一下（首击）：系统按钮不接它，只把窗口激活，那一下落到下面的行上。不用按钮的点按目标（`ListPress`）照这个规矩。
/// 判断：按下发生在窗口成为主窗口之前（按下把窗口激活，成为主窗口的时刻晚于按下事件的时间戳；两者同一个时钟，开机以来的秒数）。
enum FirstClick {
    private static var keyAt: TimeInterval = 0

    /// 启动时装一次：之后每次有窗口成为主窗口都记下时刻。
    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            keyAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 正在处理的这次按下是不是首击。
    static var isCurrent: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return false }
        return event.timestamp <= keyAt
    }
}

/// 不用 Button 的按钮（列表行里成百上千的小点按目标）：省掉每颗 Button 的焦点、按键与读屏机器，其余照按钮——
/// 按下的样子同 `PressStyle(.button)`，抬起时才算点、拖出 `slop` 再松手不算；首击（`FirstClick`）不算点、交给 `firstClick`；
/// 读屏是一颗按钮（标签由外面给）；全键盘访问打开时能 Tab 到、空格按下。
struct ListPress: ViewModifier {
    let slop: CGFloat
    let action: () -> Void
    var firstClick: () -> Void = {}
    @GestureState private var pressed = false
    /// 这次按下是不是首击（按下时定，抬起时用）。
    @State private var first: Bool?

    func body(content: Content) -> some View {
        content
            .modifier(PressFeedback(pressed: pressed, kind: .button))
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressed) { _, pressed, _ in pressed = true }
                .onChanged { _ in if first == nil { first = FirstClick.isCurrent } }
                .onEnded { drag in
                    let wasFirst = first ?? false
                    first = nil
                    guard abs(drag.translation.width) <= slop, abs(drag.translation.height) <= slop else { return }
                    if wasFirst { firstClick() } else { action() }
                })
            .modifier(KeyboardPress(action: action))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// 全键盘访问打开时（系统设置的"键盘导航"）能 Tab 到、空格按下，同系统按钮；关着时不挂：每行一份焦点机器，150 条展开要多约 24M 指令。
/// 开关在建行时读，App 开着时改了设置，之后新建的行才跟上。
private struct KeyboardPress: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if NSApp.isFullKeyboardAccessEnabled {
            content.focusable(interactions: .activate).onKeyPress(.space) { action(); return .handled }
        } else {
            content
        }
    }
}
#endif
