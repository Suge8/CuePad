#if DEBUG
import CueStore
import Foundation

/// 长对话与追加中的对话（验收会话页的滚动，iOS 与 Mac 共用）：
/// - `-CuePadLongChat YES`（配 `-CuePadDemo YES`）：演示库多一个 300 轮的会话 marathon（CuePad 项目），回答高矮悬殊——
///   一句话、整页长段落、40 行代码块、宽表、长列表轮换，每 25 轮你贴进来一段长文；看打开即最新、往上翻、回到最新。
/// - `-CuePadStream YES`（配 session 画面）：打开会话后像真的 Agent 那样一轮一轮追加（`stream`）：看新内容到达时跟随最新，
///   也查会话在跑时才有的界面（经过、子代理、回复框的停止钮）。
/// - `-CuePadBench chatdepth`（仅 iOS，配 session 画面打开 marathon）：测量脚本从最新处一路往上滑到第 1 轮，每排开一段量一次开销与掉帧（`ChatDepthBench`）。
/// - `-CuePadBench chatresize`（仅 Mac，配 session 画面打开 marathon）：测量脚本翻到深处后拖窗口边改宽，每次拖动量一次开销与掉帧（`ChatResizeBench`）。
/// - `-CuePadBench chatscroll`（仅 Mac，配 session 画面打开 marathon）：在进程内投递滚轮与触控板事件滚对话，量每圈主线程 CPU 与指令数（`ChatScrollBench`）。
extension DebugScene {
    static let longChat = "marathon"
    private static let longChatRounds = 300

    static func seedLongChat(_ store: CueStore, project: UUID?) async {
        _ = try? await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: longChat, state: .settled, title: longChat, directory: longChat, projectID: project)
        let start = Date.now.addingTimeInterval(-Double(longChatRounds) * 240)
        let turns = (0..<longChatRounds).map { round in
            let asked = start.addingTimeInterval(Double(round) * 240)
            return ChatTurn(you: prompt(round), pi: reply(round), tools: nil, asked: asked, answered: asked.addingTimeInterval(60))
        }
        try? await writeChat(longChat, turns, store: store)
    }

    /// 给 `sessionID` 像真的 Agent 那样一轮一轮追加，共 `rounds` 轮：你的话 → 每 200ms 做完一步（经过清单变长、状态在思考与跑工具之间换、
    /// 子代理名册变）→ 第 15 步落回答（高矮轮换）→ 等子代理时它交回一张机器消息卡片 → 歇下。
    static func stream(_ sessionID: String, rounds: Int = 100, store: CueStore) async {
        guard let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: sessionID))).items.first?.state else { return }
        let recorder = PiStateRecorder(store: store, hostID: session.hostID, minInterval: .zero)
        func set(_ state: PiWorkState, detail: String? = nil, agents: [PiSubagentState]) async {
            _ = try? await recorder.update(
                sessionID: sessionID, state: state, detail: detail, title: session.title, directory: session.folder, projectID: session.projectID, subagents: agents)
        }
        func write(_ messages: [PiChatMessage], _ recap: PiRecap) async {
            try? await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: messages, recap: recap))
        }
        for round in 0..<rounds {
            let seq = Int64(1_000_000 + round * 3)
            let you = PiChatMessage(sessionID: sessionID, entryID: "stream-u\(round)", seq: seq, role: .user, text: prompt(round + 1), at: .now)
            await write([you], PiRecap(pendingPrompt: you.text))
            var tools = PiChatMessage.Tools()
            for step in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                tools.record(.init(kind: step % 4 == 0 ? .said : .command, target: step % 4 == 0 ? "看一下第 \(step) 步的输出" : "pnpm test -- --run case\(step)"))
                await write([], PiRecap(pendingPrompt: you.text, pendingTools: tools))
                let helper = PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.running), action: "第 \(step) 步", startedAt: you.at)
                await set(step % 2 == 0 ? .tool : .thinking, detail: step % 2 == 0 ? "bash · pnpm test case\(step)" : nil, agents: [helper])
            }
            let answer = PiChatMessage(
                sessionID: sessionID, entryID: "stream-p\(round)", seq: seq + 1, role: .pi, text: reply(round + 1), at: .now, tools: tools, roundStartedAt: you.at)
            await write([answer], PiRecap(lastPrompt: you.text, lastReply: answer.text))
            let helper = PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.running), action: "收尾", startedAt: you.at)
            await set(.delegating, agents: [helper])
            try? await Task.sleep(for: .seconds(1))
            let returned = PiChatMessage(
                sessionID: sessionID, entryID: "stream-m\(round)", seq: seq + 2, role: .machine,
                text: "<firecode_master_event>\nhelper-\(round) 交回：\(reply(round))\n</firecode_master_event>", at: .now)
            await write([returned], PiRecap(lastPrompt: you.text, lastReply: answer.text))
            await set(.settled, agents: [PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.done), startedAt: you.at, settledAt: .now)])
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func prompt(_ round: Int) -> String {
        guard round % 25 != 0 else {
            return "第 \(round) 轮，我把日志贴过来：\n" + (1...30).map { "[\($0)] worker-\($0 % 7) retry=\($0 % 3) 连接被对端重置，正在重连第 \($0) 次" }.joined(separator: "\n")
        }
        return ["继续", "第 \(round) 轮：把上一步的结果整理成表格", "这里为什么会慢？给我看一下热点代码", "好，下一个", "列一下还剩哪些没做"][round % 5]
    }

    private static func reply(_ round: Int) -> String {
        let paragraph = "第 \(round) 轮的回答。调度器在重连时会拿到新的时间戳，所以按加入时间排序会把重连的人排到最前；改成按首次加入时间排序之后，"
            + "重连不再改变顺序，压测里 p95 从 12ms 降到 9ms，内存基本不变。另外两条超时路径还没有用例覆盖，补上之后覆盖率能到 85% 左右。"
        switch round % 6 {
        case 0: return "好的，第 \(round) 轮做完了。"
        case 1: return Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        case 2: return paragraph + "\n\n```swift\n" + (1...40).map { "let value\($0) = try await compute(\($0), retry: \($0 % 5))" }.joined(separator: "\n") + "\n```"
        case 3:
            return "| 用例 | 结果 | 耗时 | 说明 |\n|:--|:--:|--:|:--|\n"
                + (1...8).map { "| 用例 \($0) | \($0 % 3 == 0 ? "失败" : "通过") | \($0 * 13) ms | 第 \(round) 轮的第 \($0) 个检查 |" }.joined(separator: "\n")
        case 4: return (1...12).map { "- 第 \($0) 项：" + ($0 % 2 == 0 ? "已完成" : "还差一点，等上游合并") }.joined(separator: "\n")
        default: return paragraph
        }
    }
}
#endif

#if os(iOS) && DEBUG
import QuartzCore
import UIKit

/// 长对话一路往上翻到第 1 轮，每排开一段的开销：测量脚本在模拟器上真滑（程序改偏移不算用户滚动），对话每在上面排开一段
/// （`DebugHooks.chatShowsEarlier`）就从那一刻起量 800ms：点击回合、合计、最重一圈（主线程 CPU 毫秒）、指令数（百万）、掉帧。
/// `roundsBack` 是排开后最早一条离最新多少轮（按条目位置算，每轮是你的话与回答两条）；800ms 内又排开一段时上一段提前收（`windowMs`）。
/// 每段一行 `DEPTH {json}` 写进隔离库目录下的 `chatdepth.jsonl`；排开到第 1 条写 `DONE` 退出。
enum ChatDepthBench {
    private static let turns = TurnLog()
    private static var out: URL?
    private static var running: Running?

    private struct Running {
        let recorder: FrameRecorder
        let instructions: Double
        let from: Int
        let count: Int
        let started: CFTimeInterval
        let token = UUID()
    }

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "chatdepth.jsonl")
        try? Data().write(to: out)
        try? await Task.sleep(for: .seconds(4))
        self.out = out
        write("READY")
    }

    static func began(from item: Int, of count: Int) {
        guard out != nil else { return }
        finish()
        let recorder = FrameRecorder()
        recorder.start()
        let running = Running(recorder: recorder, instructions: instructionsMillions(), from: item, count: count, started: CACurrentMediaTime())
        self.running = running
        turns.begin(running.started, root: nil)
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if Self.running?.token == running.token { finish() }
        }
    }

    private static func finish() {
        guard let running else { return }
        self.running = nil
        var row = TurnLog.metrics(turns.finish(), instructions: running.instructions, frames: running.recorder.stop())
        ["clickMs", "visibleTurns", "seen", "heavy"].forEach { row[$0] = nil }
        row["roundsBack"] = (running.count - running.from + 1) / 2
        row["windowMs"] = ((CACurrentMediaTime() - running.started) * 1000).rounded()
        write("DEPTH " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        if running.from == 0 {
            write("DONE")
            exit(0)
        }
    }

    private static func write(_ line: String) {
        guard let out, let handle = try? FileHandle(forWritingTo: out) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif

#if os(macOS) && DEBUG
import AppKit

/// 长对话翻到深处后拖窗口边改宽的开销：从按住窗口边（开始拖动改大小）量到松手后 500ms：点击回合、合计、最重一圈（主线程 CPU 毫秒）、
/// 指令数（百万）、掉帧。每次拖动一行 `RESIZE {json}` 写进隔离库目录下的 `chatresize.jsonl`。
enum ChatResizeBench {
    private static let turns = TurnLog()
    private static var running: (recorder: FrameRecorder, instructions: Double, started: CFTimeInterval)?

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "chatresize.jsonl")
        try? Data("READY\n".utf8).write(to: out)
        let center = NotificationCenter.default
        for await note in center.notifications(named: NSWindow.willStartLiveResizeNotification) {
            guard let view = (note.object as? NSWindow)?.contentView else { continue }
            begin(view)
            for await _ in center.notifications(named: NSWindow.didEndLiveResizeNotification).prefix(1).map({ _ in () }) {}
            try? await Task.sleep(for: .milliseconds(500))
            finish(out)
        }
    }

    private static func begin(_ view: NSView) {
        let recorder = FrameRecorder()
        recorder.start(in: view)
        let started = CACurrentMediaTime()
        running = (recorder, instructionsMillions(), started)
        turns.begin(started, root: nil)
    }

    private static func finish(_ out: URL) {
        guard let running else { return }
        self.running = nil
        var row = TurnLog.metrics(turns.finish(), instructions: running.instructions, frames: running.recorder.stop())
        ["clickMs", "visibleTurns", "seen", "heavy"].forEach { row[$0] = nil }
        row["windowMs"] = ((CACurrentMediaTime() - running.started) * 1000).rounded()
        guard let handle = try? FileHandle(forWritingTo: out) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(("RESIZE " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self) + "\n").utf8))
        try? handle.close()
    }
}
#endif

#if os(macOS) && DEBUG
import AppKit
import QuartzCore

/// 长对话里滚轮与触控板滚动的开销（`-CuePadBench chatscroll`，配 session 画面打开 marathon）：先往上翻几趟把对话排开、量过高度，
/// 再各量三组手势（慢速触控板 600px/s、快速触控板 2400px/s、鼠标滚轮），每组下上下上共四趟，一组一行 `CHATSCROLL {json}`，量完退出。
/// 指标：主线程每圈 CPU（≥0.2ms 的圈）的 p50/p90/p99（毫秒；144Hz 一帧 6.9ms）、超 6.9ms 与 16ms 的圈数、总 CPU、进程指令数（百万，前后对比以它为准）、
/// `movedPx`（为 0 说明没滚动起来，数字作废）、`events` 与 `delivered`（应投与实际投出的事件数，不等时这一组的工作量和别组不同，数字作废）；前台时还有 display link 掉帧。
/// 别人在编译时 CPU 时间会被拖歪，指令数基本不动；热身时排开多少条随时机略变，要排除它就把初始排开的条数固定成同一个值再比（同值下三遍指令数相差不到 1%）。
/// 跑法：`-CuePadDemo YES -CuePadLongChat YES -CuePadScene session -CuePadSession marathon -CuePadWindowSize 1440x900 -CuePadOffscreen YES`，
/// 用 `open -g -n -a <app> --stdout <文件> --env … --args …` 后台启动（直接执行二进制会把应用调到前台抢焦点）；Time Profiler 按这次启动的 PID `--attach`。
/// 默认不碰真实指针、不把窗口调到前台、不向系统发事件，配 `-CuePadOffscreen YES` 在屏幕外跑：直接挪滚动视图的裁剪区原点（不经 AppKit 的滚轮事件与动画，
/// 那条路靠 display link，屏幕外不走），补发 `willStartLiveScroll` 与 `didEndLiveScroll` 两个通知（滚动区据此知道"用户在滚"）。屏幕外量不到：滚轮事件与动画那一段、
/// 指针在窗口里时每帧重设光标的成本（自定义指针的机器上很贵）、合成与掉帧。
/// 前台的两种驱动（会把应用调到前台，要在没人用电脑时跑；`pointerInWindow` 记录量的时候真实指针是否在窗口里，两种数字不能混着比）：
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
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
        }
        let primaryHeight = NSScreen.screens[0].frame.height
        let center = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        // in：对话区中央；out：窗口外的屏幕角落（取离窗口最远的那一角）
        let corners = [CGPoint(x: 20, y: 60), CGPoint(x: NSScreen.screens[0].frame.width - 20, y: 60)]
        let spot = pointer == "out"
            ? corners.max { abs($0.x - center.midX) < abs($1.x - center.midX) } ?? .zero
            : CGPoint(x: center.midX, y: primaryHeight - center.midY)
        let original = CGEvent(source: nil)?.location ?? .zero
        var pointerMoved = false
        /// 任何退出路径（含出错提前退出）都从这里走：动过指针就放回原处。
        func finish(_ code: Int32) -> Never {
            if pointerMoved { CGWarpMouseCursorPosition(original) }
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
            pointerMoved = true
            CGWarpMouseCursorPosition(spot)
            try? await Task.sleep(for: .milliseconds(500))
        }
        if driver == .hid {
            // 窗口得在指针下的最上层才发得出事件：等一会儿，等不到就不量（也不让指针白占着）
            var ready = false
            for _ in 0..<20 {
                ready = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
                if ready { break }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
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
            print("CHATSCROLL " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
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
