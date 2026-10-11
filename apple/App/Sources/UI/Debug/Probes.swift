#if DEBUG && (os(macOS) || os(iOS))
import Darwin
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Mac 与 iOS 的 `-CuePadBench` 共用的两个探针：每一帧的时间戳（`FrameRecorder`）与每圈主线程 run loop 的墙钟与 CPU（`TurnLog`）。
/// 两端只在怎么起 display link 上不同（Mac 取窗口里视图的，iOS 取主屏的），其余一份。

/// 进程已执行的指令数（百万）。别的进程抢 CPU 时 CPU 时间会被拉长，指令数几乎不受影响，前后对比以它为准。
func instructionsMillions() -> Double {
    var usage = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pidRusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return Double(usage.ri_instructions) / 1_000_000
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
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    private var waiter: CheckedContinuation<Void, Never>?
    private let port = mach_thread_self()
    private var cpuAtStart = 0.0
    private var instructionsAtStart = 0.0

    #if os(macOS)
    func start(in view: NSView) { begin(view.displayLink(target: self, selector: #selector(tick))) }
    #else
    func start() { begin(CADisplayLink(target: self, selector: #selector(tick))) }
    #endif

    private func begin(_ link: CADisplayLink) {
        cpuAtStart = mainCPUSeconds(port)
        instructionsAtStart = instructionsMillions()
        stamps = []
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        refresh = link.duration > 0 ? link.duration : refresh
        waiter?.resume()
        waiter = nil
    }

    func nextFrame() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / refresh).rounded()) - 1) }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        return [
            "mainCpuMs": ((mainCPUSeconds(port) - cpuAtStart) * 10_000).rounded() / 10,
            "instructionsM": (instructionsMillions() - instructionsAtStart).rounded(),
            "frames": stamps.count,
            "refreshHz": (1 / refresh).rounded(),
            "fps": span > 0 ? (Double(intervals.count) / span * 10).rounded() / 10 : 0,
            "droppedFrames": dropped,
            "hitches": intervals.filter { $0 > refresh * 1.5 }.count,
            "worstFrameMs": ((intervals.max() ?? 0) * 10_000).rounded() / 10,
            // 每次卡顿：[距开始的毫秒, 这一帧的毫秒]，用来分清卡在哪一刻
            "hitchesAt": zip(stamps.dropFirst(), intervals).filter { $0.1 > refresh * 1.5 }.map {
                [(($0.0 - (stamps.first ?? 0)) * 1000).rounded(), ($0.1 * 10_000).rounded() / 10]
            },
        ]
    }
}

/// 每圈主线程 run loop（醒来 → 回去睡）的墙钟与 CPU 时间；提交发生在这一圈的 BeforeWaiting，所以一圈包含一帧的更新、布局与提交。
@MainActor
final class TurnLog {
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
                self.wokeCPU = mainCPUSeconds(self.port)
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard self.recording else { return }
                self.log.append(Turn(dur: CACurrentMediaTime() - max(self.woke, self.since), cpu: mainCPUSeconds(self.port) - self.wokeCPU))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    /// 从动作发出的这一刻起量：墙钟与 CPU 的起点都在这里（动作在一圈 run loop 的中途发出，那一圈之前的工作不算）。
    func begin(_ time: CFTimeInterval) {
        log = []
        since = time
        wokeCPU = mainCPUSeconds(port)
        recording = true
    }

    func finish() -> [Turn] {
        recording = false
        return log
    }

    /// 一次交互的指标行（两端同一份键名）：
    /// - clickMs：动作发出到主线程第一次回到空闲的 CPU 毫秒（只取第一圈 ≥2ms 的 run loop；CPU 不会比墙钟长，所以取两者小的）。
    /// - totalMs、maxTurnMs：动作后量的这段时间里主线程 CPU 的总数与最重的一圈；heavy 是 ≥8ms 的各圈。
    /// - instructionsM：进程在这段时间里执行的指令数（百万）。
    static func metrics(_ log: [Turn], instructions: Double, frames: [String: Any]) -> [String: Any] {
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        let click = log.first { $0.dur >= 0.002 }
        return [
            "clickMs": ms(min(click?.cpu ?? 0, click?.dur ?? 0)),
            "totalMs": ms(log.reduce(0) { $0 + min($1.cpu, $1.dur) }),
            "maxTurnMs": ms(log.map { min($0.cpu, $0.dur) }.max() ?? 0),
            "heavy": log.filter { $0.dur >= 0.008 }.map { ms(min($0.cpu, $0.dur)) },
            "instructionsM": ((instructionsMillions() - instructions) * 10).rounded() / 10,
            "hitches": frames["hitches"] ?? 0,
            "worstMs": frames["worstFrameMs"] ?? 0,
        ]
    }
}
#endif
