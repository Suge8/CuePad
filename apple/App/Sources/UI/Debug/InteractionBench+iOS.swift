#if os(iOS) && DEBUG
import CueStore
import Darwin
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// iOS 的 `-CuePadBench interact`（配 `-CuePadDemo YES`，iPhone 标签布局）：单次交互那一下的主线程耗时，口径同 Mac 的 `InteractionBench`，
/// 每项一行 `INTERACT {json}` 写进隔离库目录下的 `interact.jsonl`（模拟器里的标准输出不好取），量完退出。
/// 动作是点击最终调用的同一条路（导航路径、`openSession`、底部栏换标签的 `select`、浮窗与面板的状态），不经触摸投递。
/// 长按菜单在进程内没有入口：由 `perf-ios.sh` 在模拟器上真按（`AWAIT` 行），从手指按下起量。每项至少做两遍：第一遍是首次（要现建视图），之后是再次。
/// 演示库缺了要量的东西时写 `FAIL 原因` 并以 1 退出；全部量完写 `DONE`。
/// - 点击回合：动作发出到主线程第一次回到空闲的主线程 CPU 毫秒（只取第一圈 ≥2ms 的 run loop）。
/// - 合计、最重一圈：动作后 800ms 里主线程 CPU 的总数与最重的一圈；指令数（百万条）是进程在这 800ms 里执行的，不随机器忙闲变。
/// - 掉帧：display link 相邻间隔超过 1.5 帧的次数。模拟器的合成与 GPU 和真机不同，只作参考。
@MainActor
enum IOSInteractionBench {
    private static let turns = IOSTurnLog()

    static func run(_ workspace: Workspace, _ navigation: Navigation) async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "interact.jsonl")
        try? Data().write(to: out)
        func write(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: out) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        /// 缺了要量的东西就整次作废：不悄悄少量几项
        func fail(_ reason: String) -> Never {
            write("FAIL " + reason)
            exit(1)
        }
        try? await Task.sleep(for: .seconds(4))
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = ((try? await store.piSessionPage(PiSessionQuery(limit: 4)))?.items ?? []).map(\.state.id)
        let tasks = ((try? await store.tasks(.inProgress, .todo))?.flatMap(\.tasks) ?? []).filter { $0.parentID == nil }.map(\.id)
        guard projects.count >= 2 else { fail("演示库里不到两个项目") }
        guard sessions.count >= 2 else { fail("演示库里不到两个会话") }
        guard let task = tasks.first else { fail("演示库里没有任务") }
        guard let idea = try? await store.cards(in: nil).first else { fail("演示库里没有未分类的灵感") }
        /// `press`：请测量脚本在这一点真按（长按或轻点由脚本按名字定），从手指按下起量；不给时从 `action` 发出起量。
        func step(_ name: String, window: Duration = .milliseconds(800), press: CGPoint? = nil, _ action: () -> Void = {}) async {
            let pressed: (() async -> Void)? = press.map { point in { await Self.touch(write, name, at: point) } }
            var row = await measure(window: window, pressed: pressed, action)
            row["name"] = name
            write("INTERACT " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
        // 书架点项目（推入项目页）→ 返回；同一个项目两遍，另一个项目再一遍
        for id in [projects[0], projects[0], projects[1]] {
            await step("书架点项目") { navigation.projectsPath.append(.project(id)) }
            await step("返回书架") { navigation.projectsPath.removeAll() }
        }
        // 底部栏换标签（含推移）
        for _ in 0..<2 {
            await step("换到 Agent") { DebugScene.selectTab(.agent) }
            await step("换回灵感") { DebugScene.selectTab(.projects) }
        }
        // Agent 页点会话（先读出这一页再推入）→ 返回
        DebugScene.selectTab(.agent)
        try? await Task.sleep(for: .seconds(1))
        for id in [sessions[0], sessions[0], sessions[1]] {
            await step("进会话页") { navigation.openSession(id, store: store) }
            await step("返回 Agent") { navigation.agentPath.removeAll() }
        }
        // Agent 列表滚动：每帧 40pt 往下再往上
        guard let scroll = Self.scrollView(in: Self.window) else { fail("Agent 页上找不到可滚的列表") }
        for _ in 0..<2 { await stepScroll("Agent 列表滚动", scroll, step: { name, action in await step(name, action) }) }
        DebugScene.selectTab(.projects)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<2 {
            await step("打开随手记") { navigation.startCapture() }
            await step("收起随手记") { navigation.endCapture() }
        }
        for _ in 0..<2 {
            await step("打开任务浮窗") { navigation.openTask(task) }
            await step("关任务浮窗") { navigation.task = nil }
        }
        for _ in 0..<2 {
            await step("挂到任务面板") { workspace.attaching = idea }
            await step("关挂到任务面板") { workspace.attaching = nil }
        }
        // 最后量长按书架上的项目卡（放在最后：万一菜单没收起，不影响前面各项）：系统的长按菜单在进程内没有入口，由 perf-ios.sh 在模拟器上真按（`AWAIT 名 x y` 是要它按的点，屏幕坐标）。
        // 从手指按下起量 1.5 秒（菜单在按住约半秒后才弹出）；松手后菜单留着，请脚本点一下空白处收起
        for _ in 0..<2 {
            guard let card = Self.longPressTarget(in: Self.window) else { fail("书架上找不到有长按菜单的项目卡") }
            await step("长按菜单", window: .milliseconds(1500), press: card)
            // 收起菜单不量（模拟器里点空白处、按 Esc 都收不起长按出来的菜单）：在进程里让菜单交互收起
            Self.dismissMenus(in: Self.window)
            try? await Task.sleep(for: .seconds(2))
        }
        write("DONE")
        exit(0)
    }

    /// 请测量脚本在 `point` 真按一下（长按或轻点由脚本按名字定），等手指按下那一刻再返回：量从按下起算。
    private static func touch(_ write: @escaping (String) -> Void, _ name: String, at point: CGPoint) async {
        await withCheckedContinuation { continuation in
            TouchProbe.arm { continuation.resume() }
            write("AWAIT \(name) \(Int(point.x)) \(Int(point.y))")
        }
    }

    private static func menuInteractions(in view: UIView?) -> [UIInteraction] {
        guard let view else { return [] }
        let here = view.interactions.filter { $0 is UIContextMenuInteraction || String(describing: type(of: $0)).contains("ClickPresentation") }
        return here + view.subviews.flatMap { menuInteractions(in: $0) }
    }

    /// 收起开着的长按菜单：系统的菜单交互收起，SwiftUI 的点按呈现交互取消。
    private static func dismissMenus(in view: UIView?) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for interaction in windows.flatMap({ menuInteractions(in: $0) }) {
            if let menu = interaction as? UIContextMenuInteraction { menu.dismissMenu() } else {
                let cancel = NSSelectorFromString("cancelInteraction")
                if interaction.responds(to: cancel) { interaction.perform(cancel) }
            }
        }
    }

    /// 书架上带长按菜单的项目卡（SwiftUI 的长按菜单在视图上挂着点按呈现交互）的中心点，屏幕坐标。
    private static func longPressTarget(in view: UIView?) -> CGPoint? {
        guard let view, !view.isHidden, view.alpha > 0, let window = view.window ?? (view as? UIWindow) else { return nil }
        let menu = view.interactions.contains { String(describing: type(of: $0)).contains("ClickPresentation") }
        let frame = view.convert(view.bounds, to: window)
        if menu, frame.width > 100, frame.height > 40, window.bounds.contains(frame) { return CGPoint(x: frame.midX, y: frame.midY) }
        for sub in view.subviews { if let found = longPressTarget(in: sub) { return found } }
        return nil
    }

    private static func stepScroll(_ name: String, _ scroll: UIScrollView, step: (String, () -> Void) async -> Void) async {
        // 滚动是持续的：量 40 帧里每帧的主线程回合与掉帧（动作只触发第一帧，之后由 display link 推）
        let driver = ScrollDriver(scroll)
        await step(name) { driver.start() }
        driver.stop()
        scroll.setContentOffset(.zero, animated: false)
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    private static func scrollView(in view: UIView?) -> UIScrollView? {
        guard let view else { return nil }
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height, !view.isHidden, view.window != nil,
           scroll.bounds.height > 300 { return scroll }
        for sub in view.subviews where !sub.isHidden { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private static func measure(window: Duration, pressed: (() async -> Void)?, _ action: () -> Void) async -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(1200))
        if let pressed { await pressed() }
        let recorder = IOSFrameRecorder()
        recorder.start()
        let wall = Date().timeIntervalSince1970
        let instructions = instructionsMillions()
        turns.begin(CACurrentMediaTime())
        action()
        try? await Task.sleep(for: window)
        let log = turns.finish()
        let frames = recorder.stop()
        let click = log.first { $0.dur >= 0.002 }
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        return [
            "clickMs": ms(min(click?.cpu ?? 0, click?.dur ?? 0)),
            "totalMs": ms(log.reduce(0) { $0 + min($1.cpu, $1.dur) }),
            "maxTurnMs": ms(log.map { min($0.cpu, $0.dur) }.max() ?? 0),
            "heavy": log.filter { $0.dur >= 0.008 }.map { ms(min($0.cpu, $0.dur)) },
            "minstr": ((instructionsMillions() - instructions) * 10).rounded() / 10,
            "hitches": frames.hitches,
            "worstMs": frames.worstMs,
            // 动作发出的时刻（与 xctrace 录制对时）
            "at": wall,
        ]
    }

    static func instructionsMillions() -> Double {
        var usage = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pidRusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return Double(usage.ri_instructions) / 1_000_000
    }
}

/// iOS 的 SDK 头文件里没有 `proc_pid_rusage`（libproc），符号在系统库里：只给测量用。
@_silgen_name("proc_pid_rusage")
private func pidRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>) -> Int32

/// 窗口里手指按下的那一刻（测量脚本在模拟器上真按的长按、轻点）：每个窗口挂一个（长按菜单弹在自己的窗口里），只看不拦，按下就报给等着的一方。
@MainActor
private final class TouchProbe: UIGestureRecognizer {
    private static var waiting: (() -> Void)?

    static func arm(_ pressed: @escaping () -> Void) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchProbe }) {
            let probe = TouchProbe(target: nil, action: nil)
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false
            probe.delaysTouchesEnded = false
            window.addGestureRecognizer(probe)
        }
        waiting = pressed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.waiting?()
        Self.waiting = nil
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// 每帧往下滚 40pt，到底往回。
@MainActor
private final class ScrollDriver: NSObject {
    private let scroll: UIScrollView
    private var link: CADisplayLink?
    private var direction: CGFloat = 1

    init(_ scroll: UIScrollView) { self.scroll = scroll }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate() }

    @objc private func tick() {
        let maxY = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        var y = scroll.contentOffset.y + 40 * direction
        if y >= maxY { y = maxY; direction = -1 } else if y <= -scroll.adjustedContentInset.top { direction = 1 }
        scroll.contentOffset.y = y
    }
}

@MainActor
private final class IOSFrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.duration > 0 { refresh = link.duration }
    }

    func stop() -> (hitches: Int, worstMs: Double) {
        link?.invalidate()
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        return (gaps.filter { $0 > refresh * 1.5 }.count, ((gaps.max() ?? 0) * 10_000).rounded() / 10)
    }
}

/// 每圈主线程 run loop 的墙钟与 CPU 时间。与 Mac 的 `TurnLog`（`InteractionBench.swift`）是同一份逻辑的两份副本，
/// 帧记录与 `FrameRecorder`（`PerfBench.swift`）同样：改一处要同改另一处，待合成两端共用的一份。
/// 已分叉一处：这里 `begin` 把 CPU 起点也挪到动作发出时，Mac 那份还只在醒来时取，合并时以这里为准。
@MainActor
private final class IOSTurnLog {
    struct Turn {
        var dur: CFTimeInterval
        var cpu: Double
    }

    private let port = mach_thread_self()
    private var woke: CFTimeInterval = 0
    private var wokeCPU = 0.0
    private var since: CFTimeInterval = 0
    private var log: [Turn] = []
    private var recording = false

    init() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated {
                self.woke = CACurrentMediaTime()
                self.wokeCPU = self.cpu()
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard self.recording else { return }
                self.log.append(Turn(dur: CACurrentMediaTime() - max(self.woke, self.since), cpu: self.cpu() - self.wokeCPU))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    private func cpu() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    /// 从动作发出的这一刻起量：墙钟与 CPU 的起点都在这里（动作在一圈 run loop 的中途发出，那一圈之前的工作不算）。
    func begin(_ time: CFTimeInterval) {
        log = []
        since = time
        wokeCPU = cpu()
        recording = true
    }

    func finish() -> [Turn] {
        recording = false
        return log
    }
}
#endif
