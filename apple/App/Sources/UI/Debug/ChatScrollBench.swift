#if os(macOS) && DEBUG
import AppKit
import QuartzCore

/// 长对话里滚轮与触控板滚动的开销（`-CuePadBench chatscroll`，配 session 画面打开 marathon，或 `-CuePadScene cue` 量 Cue 页）：先往上翻几趟把对话排开、量过高度，
/// 再各量三组手势（慢速触控板 600px/s、快速触控板 2400px/s、鼠标滚轮），每组下上下上共四趟，一组一行 `CHATSCROLL {json}`，量完退出。
/// 指标：主线程每圈 CPU（≥0.2ms 的圈）的 p50/p90/p99（毫秒；144Hz 一帧 6.9ms）、超 6.9ms 与 16ms 的圈数、总 CPU、进程指令数（百万，前后对比以它为准）、
/// `movedPx`（为 0 说明没滚动起来，数字作废）、`events` 与 `delivered`（应投与实际投出的事件数，不等时这一组的工作量和别组不同，数字作废）；前台时还有 display link 掉帧。
/// 别人在编译时 CPU 时间会被拖歪，指令数基本不动；热身时排开多少条随时机略变，要排除它就把初始排开的条数固定成同一个值再比（同值下三遍指令数相差不到 1%）。
/// 跑法：`-CuePadDemo YES -CuePadLongChat YES -CuePadScene session -CuePadSession marathon -CuePadWindowSize 1440x900 -CuePadOffscreen YES`（Cue 页把后两项场景换成 `-CuePadScene cue`），
/// 本机构建怎么起都在后台；Time Profiler 按这次启动的 PID `--attach`。
/// 默认不碰真实指针、不把窗口调到前台、不向系统发事件，配 `-CuePadOffscreen YES` 在屏幕外跑：直接挪滚动视图的裁剪区原点（不经 AppKit 的滚轮事件与动画，
/// 那条路靠 display link，屏幕外不走），补发 `willStartLiveScroll` 与 `didEndLiveScroll` 两个通知（滚动区据此知道"用户在滚"）。屏幕外量不到：滚轮事件与动画那一段、
/// 指针在窗口里时每帧重设光标的成本（自定义指针的机器上很贵）、合成与掉帧。
/// 前台的两种驱动（要占前台，配 `-CuePadForeground YES`，只在没人用电脑时跑，量完把前台与指针还回去；`pointerInWindow` 记录量的时候真实指针是否在窗口里，两种数字不能混着比）：
/// - `-CuePadScrollDriver process`：滚轮事件在进程内直接交给对话的滚动视图（`scrollWheel(with:)`），经 AppKit 的滚轮与动画，不碰指针；
/// - `-CuePadScrollDriver hid`：经窗口服务器发真实滚轮事件（本窗口不在指针下的最上层时一个事件也不发，量不了就报错退出）。
/// `-CuePadScrollPointer in|out` 在热身之后把指针移到对话区中央（in）或窗口外的屏幕角落（out），量完放回；hid 要配 in。
/// 定预算以 hid 加 in 为准：旧新各跑三遍、交替，同口径比指令数、p90/p99、超 6.9ms 与 16ms 的圈数、掉帧。
enum ChatScrollBench {
    private static let turns = TurnLog()

    private struct Event {
        var at: Double
        var dy: Double
        var phase: Int64 = 0
        var momentum: Int64 = 0
        var lines = false
    }

    private struct Gesture {
        let name: String
        let speed: Double
        let wheel: Bool
    }

    private enum Driver: String { case direct, process, hid }

    static func run() async {
        let defaults = DebugScene.defaults
        let driver = Driver(rawValue: defaults.string(forKey: "CuePadScrollDriver") ?? "") ?? .direct
        let pointer = defaults.string(forKey: "CuePadScrollPointer")
        var found: (NSWindow, NSScrollView)?
        for _ in 0..<90 {
            try? await Task.sleep(for: .seconds(1))
            if let window = NSApp.windows.first(where: { $0.styleMask.contains(.resizable) && $0.styleMask.contains(.fullSizeContentView) }),
               let content = window.contentView, let scroll = chatScroll(in: content) { found = (window, scroll); break }
        }
        guard let (window, scroll) = found else { print("CHATSCROLL-ERR 找不到对话的滚动视图"); fflush(stdout); exit(1) }
        try? await Task.sleep(for: .seconds(3))
        if driver != .direct {
            DebugForeground.require(window, for: "CuePadScrollDriver \(driver.rawValue)")
            try? await Task.sleep(for: .seconds(1))
        }
        let primaryHeight = NSScreen.screens[0].frame.height
        let center = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        // in：对话区中央；out：窗口外的屏幕角落（取离窗口最远的那一角）
        let corners = [CGPoint(x: 20, y: 60), CGPoint(x: NSScreen.screens[0].frame.width - 20, y: 60)]
        let spot = pointer == "out"
            ? corners.max { abs($0.x - center.midX) < abs($1.x - center.midX) } ?? .zero
            : CGPoint(x: center.midX, y: primaryHeight - center.midY)
        /// 任何退出路径（含出错提前退出）都从这里走：借了前台、动过指针就还回去。
        func finish(_ code: Int32) -> Never {
            DebugForeground.giveBack()
            fflush(stdout)
            exit(code)
        }
        var attempted = 0, delivered = 0

        func deliver(_ event: Event, real: Bool) {
            attempted += 1
            let clip = scroll.contentView
            switch driver {
            case .direct:
                // 直接挪裁剪区的原点
                var origin = clip.bounds.origin
                origin.y -= event.dy * (event.lines ? 10 : 1)
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                scroll.reflectScrolledClipView(clip)
                delivered += 1
            case .process, .hid:
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: event.lines ? .line : .pixel, wheelCount: 1, wheel1: Int32(event.dy.rounded()), wheel2: 0, wheel3: 0)
                else { return }
                if !event.lines {
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
                    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: event.momentum)
                }
                if real, driver == .hid {
                    guard NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
                    cg.location = spot
                    cg.post(tap: .cghidEventTap)
                    delivered += 1
                } else if let ns = NSEvent(cgEvent: cg) {
                    scroll.scrollWheel(with: ns)
                    delivered += 1
                }
            }
        }
        func play(up: Bool, _ gesture: Gesture, real: Bool = false) async {
            let clock = ContinuousClock()
            let start = clock.now
            if driver == .direct {
                // 滚动区据这两个通知知道"用户在滚"（贴底的跟随据此不把偏移拉回去）：手势的头尾补发
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            }
            defer { if driver == .direct { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) } }
            for event in Self.events(up: up, gesture) {
                try? await clock.sleep(until: start + .seconds(event.at))
                deliver(event, real: real)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // 热身（指针还没动）：往上翻几趟排开更早的对话、量过各段的高度，再回来一点
        let warm = Gesture(name: "warm", speed: 2400, wheel: false)
        for _ in 0..<7 { await play(up: true, warm) }
        for _ in 0..<2 { await play(up: false, warm) }
        try? await Task.sleep(for: .seconds(1))
        let movesPointer = driver != .direct && (pointer == "in" || pointer == "out")
        if movesPointer {
            DebugForeground.movePointer(to: spot)
            try? await Task.sleep(for: .milliseconds(500))
        }
        if driver == .hid {
            // 窗口得在指针下的最上层才发得出事件：等一会儿，等不到就不量（也不让指针白占着）
            var ready = false
            for _ in 0..<20 {
                ready = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
                if ready { break }
                DebugForeground.require(window, for: "CuePadScrollDriver hid")
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard ready else {
                print("CHATSCROLL-ERR 本窗口不在指针下的最上层")
                finish(1)
            }
        }
        let pointerInWindow = window.frame.contains(NSEvent.mouseLocation)

        for gesture in [Gesture(name: "slow", speed: 600, wheel: false), Gesture(name: "fast", speed: 2400, wheel: false), Gesture(name: "wheel", speed: 0, wheel: true)] {
            let recorder = FrameRecorder()
            if driver != .direct { recorder.start(in: window.contentView!) }
            let instructions = instructionsMillions()
            let started = CACurrentMediaTime()
            turns.begin(started, root: nil)
            attempted = 0
            delivered = 0
            var moved = 0.0
            for index in 0..<4 {
                let before = scroll.contentView.bounds.origin.y
                await play(up: index % 2 == 1, gesture, real: true)
                moved += abs(scroll.contentView.bounds.origin.y - before)
            }
            let log = turns.finish()
            var row = TurnLog.metrics(log, instructions: instructions, frames: driver == .direct ? FrameRecorder.Hitches() : recorder.stop())
            ["clickMs", "visibleTurns", "seen", "heavy", "hitchesAt"].forEach { row[$0] = nil }
            if driver == .direct { ["hitches", "worstMs"].forEach { row[$0] = nil } }
            let cpu = log.log.map { min($0.cpu, $0.dur) * 1000 }.filter { $0 >= 0.2 }.sorted()
            func percentile(_ p: Double) -> Double { cpu.isEmpty ? 0 : (cpu[min(cpu.count - 1, Int(Double(cpu.count) * p))] * 100).rounded() / 100 }
            row["set"] = gesture.name
            row["turns"] = cpu.count
            row["p50"] = percentile(0.5)
            row["p90"] = percentile(0.9)
            row["p99"] = percentile(0.99)
            row["over6.9"] = cpu.filter { $0 > 6.9 }.count
            row["over16"] = cpu.filter { $0 > 16 }.count
            row["movedPx"] = moved.rounded()
            row["wallS"] = ((CACurrentMediaTime() - started) * 10).rounded() / 10
            // 窗口不在指针下时 hid 会丢事件：投递数与应投数不等，这一组的滚动工作量就和别组不同，数字作废
            row["events"] = attempted
            row["delivered"] = delivered
            row["driver"] = driver.rawValue
            row["pointerInWindow"] = pointerInWindow
            row["frontmostIsMe"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            print(jsonLine("CHATSCROLL", row))
            fflush(stdout)
            try? await Task.sleep(for: .milliseconds(500))
        }
        finish(0)
    }

    /// 对话的滚动视图：窗口里文档比可见区高两倍以上的最大那个（代码块、表格的横向滚动区不满足）。
    private static func chatScroll(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > 300, let document = scroll.documentView,
               document.frame.height > 2 * scroll.contentView.bounds.height,
               best.map({ scroll.frame.width * scroll.frame.height > $0.frame.width * $0.frame.height }) ?? true { best = scroll }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best
    }

    /// 一趟手势的事件：触控板是手指按 `speed`（px/s）匀速滑 1.2 秒（120Hz），抬手后惯性按 0.3 秒的时间常数衰减；滚轮是每 30ms 一格 3 行共 40 格。
    private static func events(up: Bool, _ gesture: Gesture) -> [Event] {
        let sign = up ? 1.0 : -1.0
        if gesture.wheel { return (0..<40).map { Event(at: Double($0) * 0.03, dy: sign * 3, lines: true) } }
        let step = 1.0 / 120
        var events: [Event] = [], carry = 0.0, time = 0.0
        func push(_ velocity: Double, phase: Int64 = 0, momentum: Int64 = 0) {
            carry += velocity * step
            let dy = carry.rounded()
            carry -= dy
            events.append(Event(at: time, dy: dy, phase: phase, momentum: momentum))
            time += step
        }
        for index in 0..<Int(1.2 / step) { push(sign * gesture.speed, phase: index == 0 ? 1 : 2) }
        events.append(Event(at: time, dy: 0, phase: 4))
        time += step
        var velocity = sign * gesture.speed, first = true
        while abs(velocity) * step > 0.7 {
            push(velocity, momentum: first ? 1 : 2)
            first = false
            velocity *= exp(-step / 0.3)
        }
        events.append(Event(at: time, dy: 0, momentum: 3))
        return events
    }
}
#endif
