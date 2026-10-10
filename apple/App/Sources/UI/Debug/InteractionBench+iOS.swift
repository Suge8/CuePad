#if os(iOS) && DEBUG
import CueStore
import Darwin
import QuartzCore
import UIKit

/// iOS 的 `-CuePadBench interact`（配 `-CuePadDemo YES`，iPhone 标签布局）：单次交互那一下的主线程耗时，口径同 Mac 的 `InteractionBench`，
/// 每项一行 `INTERACT {json}` 写进隔离库目录下的 `interact.jsonl`（模拟器里的标准输出不好取），量完退出。
/// 动作是点击最终调用的同一条路（导航路径、`openSession`、底部栏换标签的 `select`、浮窗与面板的状态），不经触摸投递。
/// 长按菜单不在里面：SwiftUI 的长按菜单没有可从进程内触发的入口。每项至少做两遍：第一遍是首次（要现建视图），之后是再次。
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
        try? await Task.sleep(for: .seconds(4))
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = ((try? await store.piSessionPage(PiSessionQuery(limit: 4)))?.items ?? []).map(\.state.id)
        let tasks = ((try? await store.tasks(.inProgress, .todo))?.flatMap(\.tasks) ?? []).filter { $0.parentID == nil }.map(\.id)
        let ideas = (try? await store.cards(in: nil)) ?? []
        func step(_ name: String, _ action: () -> Void) async {
            var row = await measure(action)
            row["name"] = name
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
            if let handle = try? FileHandle(forWritingTo: out) {
                handle.seekToEndOfFile()
                handle.write(Data(("INTERACT " + line + "\n").utf8))
                try? handle.close()
            }
        }
        // 书架点项目（推入项目页）→ 返回；同一个项目两遍，另一个项目再一遍
        for id in [projects.first, projects.first, projects.dropFirst().first].compactMap({ $0 }) {
            await step("书架点项目") { navigation.projectsPath.append(.project(id)) }
            await step("返回书架") { navigation.projectsPath.removeAll() }
        }
        // 底部栏换标签（含推移）
        for _ in 0..<2 {
            await step("换到 Agent") { DebugHooks.selectTab(.agent) }
            await step("换回灵感") { DebugHooks.selectTab(.projects) }
        }
        // Agent 页点会话（先读出这一页再推入）→ 返回
        DebugHooks.selectTab(.agent)
        try? await Task.sleep(for: .seconds(1))
        for id in [sessions.first, sessions.first, sessions.dropFirst().first].compactMap({ $0 }) {
            await step("进会话页") { navigation.openSession(id, store: store) }
            await step("返回 Agent") { navigation.agentPath.removeAll() }
        }
        // Agent 列表滚动：每帧 40pt 往下再往上
        if let scroll = Self.scrollView(in: Self.window) {
            for _ in 0..<2 { await stepScroll("Agent 列表滚动", scroll, step: step) }
        }
        DebugHooks.selectTab(.projects)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<2 {
            await step("打开随手记") { navigation.startCapture() }
            await step("收起随手记") { navigation.endCapture() }
        }
        for id in [tasks.first, tasks.first].compactMap({ $0 }) {
            await step("打开任务浮窗") { navigation.openTask(id) }
            await step("关任务浮窗") { navigation.task = nil }
        }
        for idea in [ideas.first, ideas.first].compactMap({ $0 }) {
            await step("挂到任务面板") { workspace.attaching = idea }
            await step("关挂到任务面板") { workspace.attaching = nil }
        }
        exit(0)
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

    private static func measure(_ action: () -> Void) async -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(1200))
        let recorder = IOSFrameRecorder()
        recorder.start()
        let wall = Date().timeIntervalSince1970
        let instructions = instructionsMillions()
        turns.begin(CACurrentMediaTime())
        action()
        try? await Task.sleep(for: .milliseconds(800))
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

/// 每圈主线程 run loop 的墙钟与 CPU 时间（同 Mac 的 `TurnLog`）。
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

    func begin(_ time: CFTimeInterval) {
        log = []
        since = time
        recording = true
    }

    func finish() -> [Turn] {
        recording = false
        return log
    }
}
#endif
