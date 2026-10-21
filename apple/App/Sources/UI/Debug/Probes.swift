#if DEBUG && (os(macOS) || os(iOS))
import Darwin
import QuartzCore
#if os(macOS)
import AppKit
#endif

/// Mac 与 iOS 的 `-CuePadBench` 共用的两个探针：每一帧的时间戳（`FrameRecorder`）与每圈主线程 run loop 的墙钟与 CPU（`TurnLog`）。
/// 两端只在怎么起 display link 上不同（Mac 取窗口里视图的，iOS 取主屏的），其余一份。

/// 测量结果的一行：`标签 {json}`，键排序（脚本按标签认行）。
func jsonLine(_ tag: String, _ row: [String: Any]) -> String {
    tag + " " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
}

/// 进程已执行的指令数（百万）。别的进程抢 CPU 时 CPU 时间会被拉长，指令数几乎不受影响，前后对比以它为准。
func instructionsMillions() -> Double { Double(processCounters().instructions) / 1_000_000 }

/// 进程累计执行的指令数与 CPU 周期数（内核的性能计数器）。
func processCounters() -> (instructions: UInt64, cycles: UInt64) {
    var usage = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pidRusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return (usage.ri_instructions, usage.ri_cycles)
}

/// 进程累计消耗的能量（毫焦，内核按 CPU 与 GPU 等的活动估算）。
func energyMillijoules() -> Double {
    var usage = rusage_info_v6()
    _ = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pidRusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    return Double(usage.ri_energy_nj) / 1_000_000
}

#if os(macOS)
private func pidRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>) -> Int32 {
    proc_pid_rusage(pid, flavor, buffer)
}
#else
/// iOS 的 SDK 头文件里没有 `proc_pid_rusage`（libproc），符号在系统库里：只给测量用。
@_silgen_name("proc_pid_rusage")
private func pidRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>) -> Int32
#endif

/// 主线程累计占用的 CPU 秒（用户态加内核态）。
private func mainCPUSeconds(_ port: mach_port_t) -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
}

/// 用 display link 记下每一帧的时间戳；帧间隔超过刷新间隔 1.5 倍的算掉帧。
final class FrameRecorder: NSObject {
    /// 掉帧次数、最长一帧（毫秒）与每次掉帧 [距开始的毫秒, 这一帧的毫秒]。
    struct Hitches {
        var count = 0
        var worstMs = 0.0
        var at: [[Double]] = []
    }

    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60

    #if os(macOS)
    func start(in view: NSView) { begin(view.displayLink(target: self, selector: #selector(tick))) }
    #else
    func start() { begin(CADisplayLink(target: self, selector: #selector(tick))) }
    #endif

    private func begin(_ link: CADisplayLink) {
        stamps = []
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        refresh = link.duration > 0 ? link.duration : refresh
    }

    func stop() -> Hitches {
        link?.invalidate()
        link = nil
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let slow = zip(stamps.dropFirst(), intervals).filter { $0.1 > refresh * 1.5 }
        return Hitches(
            count: slow.count, worstMs: ((intervals.max() ?? 0) * 10_000).rounded() / 10,
            at: slow.map { [(($0.0 - (stamps.first ?? 0)) * 1000).rounded(), ($0.1 * 10_000).rounded() / 10] })
    }
}

/// 每圈主线程 run loop（醒来 → 回去睡）的墙钟与 CPU 时间；提交发生在这一圈的 BeforeWaiting，所以一圈包含一帧的更新、布局与提交。
final class TurnLog {
    struct Turn {
        var dur: CFTimeInterval
        var cpu: Double
        /// 这一圈醒来的时刻（`CACurrentMediaTime`）。
        var at: CFTimeInterval
        /// 这一圈里进程执行的指令与周期（含别的线程，这一圈里主线程占大头）。
        var instructions: UInt64
        var cycles: UInt64
    }

    private let port = mach_thread_self()
    private var woke: CFTimeInterval = 0
    private var wokeCPU = 0.0
    private var wokeCounters: (instructions: UInt64, cycles: UInt64) = (0, 0)
    private var since: CFTimeInterval = 0
    private var log: [Turn] = []
    private var recording = false
    /// 看画面有没有变的那棵图层树（窗口的根图层）与动作发出时它的指纹。
    private var root: CALayer?
    private var baseline = 0
    /// 画面第一次变发生在第几圈（`log` 的下标）；还没变为 nil。
    private var changedAt: Int?

    init() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated {
                self.woke = CACurrentMediaTime()
                self.wokeCPU = mainCPUSeconds(self.port)
                self.wokeCounters = processCounters()
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard self.recording else { return }
                let counters = processCounters()
                self.log.append(Turn(
                    dur: CACurrentMediaTime() - max(self.woke, self.since), cpu: mainCPUSeconds(self.port) - self.wokeCPU, at: max(self.woke, self.since),
                    instructions: counters.instructions - self.wokeCounters.instructions, cycles: counters.cycles - self.wokeCounters.cycles))
                // 这一圈的提交已做完：画面和动作发出时不一样了，这一圈就是第一次变（指纹的计算不在任何一圈的 CPU 里）
                if self.changedAt == nil, let root = self.root, Self.fingerprint(root) != self.baseline { self.changedAt = self.log.count - 1 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    /// 从动作发出的这一刻起量：墙钟与 CPU 的起点都在这里（动作在一圈 run loop 的中途发出，那一圈之前的工作不算）。
    func begin(_ time: CFTimeInterval, root: CALayer?) {
        log = []
        since = time
        self.root = root
        baseline = root.map(Self.fingerprint) ?? 0
        changedAt = nil
        wokeCPU = mainCPUSeconds(port)
        wokeCounters = processCounters()
        recording = true
    }

    /// 这一次从哪一刻起量（`begin` 给的时刻）。
    var began: CFTimeInterval { since }

    func finish() -> (log: [Turn], changedAt: Int?, start: CFTimeInterval) {
        recording = false
        return (log, changedAt, since)
    }

    /// 画面的指纹：窗口图层树里看得见的层（不隐藏、不透明）的位置、大小、变换、透明度、底色、边框、圆角、阴影与内容。
    /// 不含图层对象本身：换了个什么都不画的层不算变。动画只改显示层、不改模型层，所以不会因为转着的图标而变。
    private static func fingerprint(_ layer: CALayer) -> Int {
        var hasher = Hasher()
        func visit(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            // 没有大小、没有内容、没有下级的层什么也不画
            if layer.bounds.isEmpty, layer.contents == nil, layer.sublayers?.isEmpty != false { return }
            hasher.combine(layer.position.x)
            hasher.combine(layer.position.y)
            hasher.combine(layer.bounds.width)
            hasher.combine(layer.bounds.height)
            hasher.combine(layer.opacity)
            // 按下、缩放、旋转这类只改变换的变化也要看得到
            let t = layer.transform
            for value in [t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24, t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44] {
                hasher.combine(value)
            }
            hasher.combine(layer.backgroundColor)
            hasher.combine(layer.borderWidth)
            hasher.combine(layer.borderColor)
            hasher.combine(layer.cornerRadius)
            hasher.combine(layer.shadowOpacity)
            hasher.combine(layer.shadowRadius)
            if let contents = layer.contents { hasher.combine(ObjectIdentifier(contents as AnyObject)) }
            for sublayer in layer.sublayers ?? [] { visit(sublayer) }
        }
        visit(layer)
        return hasher.finalize()
    }

    /// 一次交互的指标行（两端同一份键名）：
    /// - clickMs：动作发出到画面第一次变（含这次变化的第一帧提交）为止，主线程的全部 CPU 毫秒，跨多圈求和；挪到下一圈的活照样算进去，直到画面第一次变
    ///   （CPU 不会比墙钟长，每圈取两者小的）。画面在量的这段时间里一直没变时 `seen` 为 false，clickMs 是整段的合计。
    /// - visibleTurns：clickMs 里有几圈。
    /// - clickInstructionsM、clickGHz：clickMs 那几圈里进程执行的指令（百万）与每 CPU 毫秒跑了多少周期：活一样多时 clickMs 翻倍而指令不变、
    ///   GHz 减半，是这台机器那一刻跑得慢（空闲一会儿后的第一下，性能核常还没升频），不是多做了活。
    /// - totalMs、maxTurnMs：动作后量的这段时间里主线程 CPU 的总数与最重的一圈；heavy 是 ≥3ms 的各圈（几毫秒醒来、几毫秒 CPU）。
    /// - instructionsM：进程在这段时间里执行的指令数（百万）。
    private static func ghz(_ turns: some Collection<Turn>) -> Double {
        let cpu = turns.reduce(0) { $0 + $1.cpu }
        return cpu > 0 ? (Double(turns.reduce(0) { $0 + $1.cycles }) / cpu / 1e7).rounded() / 100 : 0
    }

    static func metrics(_ turns: (log: [Turn], changedAt: Int?, start: CFTimeInterval), instructions: Double, frames: FrameRecorder.Hitches) -> [String: Any] {
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        let log = turns.log
        let visible = log.prefix((turns.changedAt ?? log.count - 1) + 1)
        return [
            "clickMs": ms(visible.reduce(0) { $0 + min($1.cpu, $1.dur) }),
            "visibleTurns": visible.count,
            "clickInstructionsM": (Double(visible.reduce(0) { $0 + $1.instructions }) / 100_000).rounded() / 10,
            "clickGHz": ghz(visible),
            "seen": turns.changedAt != nil,
            "totalMs": ms(log.reduce(0) { $0 + min($1.cpu, $1.dur) }),
            "maxTurnMs": ms(log.map { min($0.cpu, $0.dur) }.max() ?? 0),
            // ≥3ms 的各圈：[动作发出后第几毫秒醒来, 这一圈的 CPU 毫秒]
            "heavy": log.filter { min($0.cpu, $0.dur) >= 0.003 }.map { [((($0.at - turns.start) * 1000).rounded()), ms(min($0.cpu, $0.dur))] },
            "instructionsM": ((instructionsMillions() - instructions) * 10).rounded() / 10,
            "hitches": frames.count,
            "worstMs": frames.worstMs,
            // 每次掉帧：[距开始的毫秒, 这一帧的毫秒]
            "hitchesAt": frames.at,
        ]
    }
}

/// 界面里的测量点：项目页内容排完（`content`，`ProjectPage` 分帧出完最后一段，Mac）、Cue 页的对话出现（`cue`）。只在 Debug 构建里由视图调用，
/// `interact` 等它出现再开始量，或拿它的时刻算到内容出现用了多久。
enum PerfProbe {
    /// 同一个事件可以有几处同时在等：每一处都要醒。
    private static var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) static var firstSeen: [String: Date] = [:]
    /// 每个事件最近一次出现的时刻（`CACurrentMediaTime`）。
    private(set) static var lastSeen: [String: CFTimeInterval] = [:]

    static func mark(_ event: String) {
        if firstSeen[event] == nil { firstSeen[event] = .now }
        lastSeen[event] = CACurrentMediaTime()
        for continuation in waiting.removeValue(forKey: event) ?? [] { continuation.resume() }
    }

    static func wait(for event: String) async {
        await withCheckedContinuation { waiting[event, default: []].append($0) }
    }

    /// 本进程启动的时刻（内核记的）：冷启动从这里起算。
    static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
#endif
