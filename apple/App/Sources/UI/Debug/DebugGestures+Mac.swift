#if os(macOS) && DEBUG
import AppKit

/// `-CuePadClick` 里除点按外的几步（录全屏预览的缩放、看图、翻页用；坐标同点按，主窗口里的点、左上为原点）：
/// - `dbl:x,y` 双击；`drag:x1,y1,x2,y2` 按住拖过去（约半秒）；
/// - `pinch:x,y,倍数` 触控板捏合（大于 1 是放大，约半秒）；`smart:x,y` 智能缩放（双指轻点两下）；
/// - `swipe:x,y,dx,dy` 触控板双指滑动（dx、dy 是手指走的点数，往右、往下为正；约 0.3 秒，没有惯性）：翻页照真的走；
///   滚动视图自己的滚动（放大后的图双指看图）合成不了——系统的滚动视图在别的线程按窗口服务器送来的滑动滚（responsive scrolling），不认合成的；
///   放大后看图用 `drag`；
/// - `left`、`right`、`space` 按一下那个键；`wait:秒` 多等一会儿；
/// - `measure:标签` 起量、`measure` 收：这一段主线程的掉帧（display link 的回调间隔，`FrameRecorder`）与进程执行的指令数，
///   写一行 `PREVIEW-MEASURE 标签 {json}` 进日志（前后两个检出跑同一串步骤对比）。
/// 捏合、智能缩放与滑动是窗口服务器发来的同一种事件（`CGEvent` 的手势与带阶段的滚动），在本进程里合成后交给那一点的视图
/// （`NSScrollView` 的放大与回弹都走系统自己的那一套）；滑动先过全屏页的翻页（`scrollGate`）。
/// 物理触控板的力度与惯性合成不了：惯性滚动、手指停住再松开这类节奏只能人工验。
extension DebugScene {
    /// 全屏预览的翻页先看一下这次滚动（`PageInput`，开着时才有）：接下了为 true。
    static var scrollGate: ((NSEvent) -> Bool)?

    /// 认得这一步就做完、返回 true。
    static func gesture(_ step: String, in window: NSWindow) async -> Bool {
        let (name, rest) = step.contains(":") ? (String(step.prefix { $0 != ":" }), step.drop { $0 != ":" }.dropFirst()) : (step, Substring())
        let n = rest.split(separator: ",").compactMap { Double($0) }
        switch (name, n.count) {
        case ("wait", 1): try? await Task.sleep(for: .seconds(n[0]))
        case ("measure", _): measure(rest.isEmpty ? nil : String(rest), in: window)
        case ("left", 0), ("right", 0), ("space", 0): key(name, in: window)
        case ("dbl", 2):
            for count in 1...2 {
                queue(mouse(.leftMouseDown, n[0], n[1], in: window, clicks: count))
                queue(mouse(.leftMouseUp, n[0], n[1], in: window, clicks: count))
                try? await Task.sleep(for: .milliseconds(80))
            }
        case ("drag", 4):
            queue(mouse(.leftMouseDown, n[0], n[1], in: window))
            for i in 1...Self.frames {
                let t = Double(i) / Double(Self.frames)
                try? await Task.sleep(for: Self.frame)
                queue(mouse(.leftMouseDragged, n[0] + (n[2] - n[0]) * t, n[1] + (n[3] - n[1]) * t, in: window))
            }
            queue(mouse(.leftMouseUp, n[2], n[3], in: window))
        case ("pinch", 3):
            let per = pow(n[2], 1 / Double(Self.frames)) - 1
            send(magnify(n[0], n[1], in: window, phase: 1, by: 0))
            for _ in 0..<Self.frames {
                try? await Task.sleep(for: Self.frame)
                send(magnify(n[0], n[1], in: window, phase: 2, by: per))
            }
            send(magnify(n[0], n[1], in: window, phase: 4, by: 0))
        case ("smart", 2):
            send(cgEvent(n[0], n[1], in: window) { $0.type = Self.gestureType; $0.setIntegerValueField(Self.gestureSubtype, value: 22) })
        case ("swipe", 4):
            // 先过全屏页的翻页（`scrollGate`，同它的本地事件监听），没接下的交给开始时指针下的视图（同系统：一次滑动不换人接）。
            // 窗口不派发合成的滚动、滚动视图也不接挂在窗口上的、从它的内容视图一路传上来的合成滚动（它们按触控板上的手指认一次滑动）：
            // 直接交给那里的滚动视图一份不挂窗口的同样的滚动
            var target: NSView?
            let steps = Self.frames / 2
            for i in 0...steps + 1 {
                let phase: Int64 = i == 0 ? 1 : i == steps + 1 ? 4 : 2
                let dx = phase == 2 ? n[2] / Double(steps) : 0, dy = phase == 2 ? n[3] / Double(steps) : 0
                guard let event = scroll(n[0], n[1], in: window, phase: phase, dx: dx, dy: dy) else { break }
                let gated = scrollGate?(event)
                if gated != true {
                    target = target ?? window.contentView?.superview?.hitTest(event.locationInWindow).map { $0.enclosingScrollView ?? $0 }
                    scroll(n[0], n[1], in: window, phase: phase, dx: dx, dy: dy, detached: true).map { target?.scrollWheel(with: $0) }
                }
                try? await Task.sleep(for: Self.frame)
            }
        default: return false
        }
        return true
    }

    /// 正在量的那一段：标签、帧、起量时的指令数（百万）。
    private static var measuring: (label: String, frames: FrameRecorder, instructions: Double)?

    private static func measure(_ label: String?, in window: NSWindow) {
        if let label, let view = window.contentView {
            let frames = FrameRecorder()
            frames.start(in: view)
            measuring = (label, frames, instructionsMillions())
            return
        }
        guard let (label, frames, instructions) = measuring else { return }
        measuring = nil
        let hitches = frames.stop()
        NSLog("%@", jsonLine("PREVIEW-MEASURE \(label)", [
            "hitches": hitches.count, "worstMs": hitches.worstMs, "instructionsM": (instructionsMillions() - instructions).rounded(),
        ]))
    }

    private static let frames = 30
    private static let frame = Duration.milliseconds(16)
    private static let gestureType = CGEventType(rawValue: 29)!
    private static let gestureSubtype = CGEventField(rawValue: 110)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let magnification = CGEventField(rawValue: 113)!

    /// 点按与按键排进事件队列（同真点：本地事件监听在取事件时看到它们）；手势与滚动当场派发，按窗口里那一点交给那里的视图。
    private static func queue(_ event: NSEvent?) {
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    /// 捏合与智能缩放直接交给那一点的视图：窗口派发手势要认触控板上的手指，合成的没有。
    private static func send(_ event: NSEvent?) {
        guard let event, let view = event.window?.contentView?.superview?.hitTest(event.locationInWindow) else { return }
        if event.type == .magnify { view.magnify(with: event) } else { view.smartMagnify(with: event) }
    }

    private static func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, in window: NSWindow, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: window.frame.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    private static func magnify(_ x: Double, _ y: Double, in window: NSWindow, phase: Int64, by amount: Double) -> NSEvent? {
        cgEvent(x, y, in: window) { event in
            event.type = gestureType
            event.setIntegerValueField(gestureSubtype, value: 8)
            event.setIntegerValueField(gesturePhase, value: phase)
            event.setDoubleValueField(magnification, value: amount)
        }
    }

    private static func scroll(_ x: Double, _ y: Double, in window: NSWindow, phase: Int64, dx: Double, dy: Double, detached: Bool = false) -> NSEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        else { return nil }
        if detached { placeDetached(event, x, y, in: window) } else { place(event, x, y, in: window) }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        return NSEvent(cgEvent: event)
    }

    private static func cgEvent(_ x: Double, _ y: Double, in window: NSWindow, _ configure: (CGEvent) -> Void) -> NSEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        configure(event)
        place(event, x, y, in: window)
        return NSEvent(cgEvent: event)
    }

    /// 事件属于这扇窗、落在窗口里这一点（左上为原点）。窗口里的位置只有私有的 `CGEventSetWindowLocation` 设得了（只用在调试构建）：
    /// 公开的只有全局位置，挂上窗口号（51）后 `locationInWindow` 不再从它换算。
    private static func place(_ event: CGEvent, _ x: Double, _ y: Double, in window: NSWindow) {
        let screen = window.convertPoint(toScreen: NSPoint(x: x, y: window.frame.height - y))
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.setIntegerValueField(windowNumber, value: Int64(window.windowNumber))
        setWindowLocation?(event, CGPoint(x: x, y: y))
        // 合成的事件时刻是 0：滚动视图按相邻几下的时刻算速度
        event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// 不挂窗口的事件，`locationInWindow` 就是屏幕坐标（主屏左下为原点）：让它等于窗口里这一点。
    private static func placeDetached(_ event: CGEvent, _ x: Double, _ y: Double, in window: NSWindow) {
        event.location = CGPoint(x: x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - (window.frame.height - y))
        event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private static let windowNumber = CGEventField(rawValue: 51)!
    private static let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self) }

    private static func key(_ name: String, in window: NSWindow) {
        let (code, character): (UInt16, Int) = switch name {
        case "left": (123, NSLeftArrowFunctionKey)
        case "right": (124, NSRightArrowFunctionKey)
        default: (49, 0x20)
        }
        let text = String(Character(UnicodeScalar(character)!))
        let flags: NSEvent.ModifierFlags = character == 0x20 ? [] : [.function, .numericPad]
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            queue(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
    }
}
#endif
