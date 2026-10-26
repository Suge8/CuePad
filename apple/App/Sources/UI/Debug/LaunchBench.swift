#if os(macOS) && DEBUG
import AppKit
import Darwin
import QuartzCore

/// `-CuePadBench launch`（`xc.sh perf launch mac`，perf-launch.sh）：冷启动的几个时刻，打一行 `LAUNCH {json}` 后退出。
/// 时刻都是 `CLOCK_UPTIME_RAW` 的纳秒（同 python 的 `time.monotonic_ns`），脚本减去 exec 成 CuePad 的那一刻（app.py 记的 `execAt`）：
/// - `entry`：进到 `main`（之前是 dyld 加载与静态初始化）。
/// - `window`：主窗口上屏后第一次提交做完（那一圈 run loop 的 BeforeWaiting 末尾，提交在它之前）。
/// - `content`：首屏内容出来（Cue 页的对话 `cue`、项目页排完 `content`，`PerfProbe`）后第一次提交做完。
/// - `interactive`：内容出来之后主线程最后一圈长任务（≥50ms 的一圈 run loop，同 Long Tasks API）结束的时刻，没有就是 `content`；
///   之后连着 `quiet` 没有长任务才算定。点在长任务里要等它做完才有回应。
/// - `long`：从 `main` 起每一圈长任务的 [开始, 结束]。
/// 每个时刻另记到那一刻主线程执行的指令（`…MainM`，百万）、整个进程的（`…AllM`，含后台线程，随它们那一刻做到哪浮动）与主线程的 CPU 毫秒（`…CPUMs`）：
/// 指令不随机器忙闲变，前后对比以主线程的为准；CPU 比墙钟短得多时主线程是在等（机器忙时等 CPU，或者等锁、等读盘）。
/// 主线程与进程的计数从 exec 之前 app.py 那段 python 算起（`entry` 那一截，每次相同，前后对比时抵消）。
/// `-CuePadTraceWait YES`（脚本带着 CUEPAD_TRACE 时）：进 `main` 就写 `AWAIT trace <PID>` 停着，等按 PID 开录了发来 SIGUSR1 再往下走，时刻从放行时算。
enum LaunchBench {
    static let active = DebugScene.defaults.string(forKey: "CuePadBench") == "launch"
    private static let longTurn: UInt64 = 50_000_000
    private static let quiet: UInt64 = 1_000_000_000
    /// 到这么久还没量完就照报（没量到的几项为空）并以 1 退出：脚本按失败处理。
    private static let limit: Duration = .seconds(30)

    private struct Stamp {
        var at: UInt64
        var mainM: Double
        var allM: Double
        var cpuMs: Double
    }

    private static let port = mach_thread_self()
    private static var woke: UInt64 = 0
    private static var presented = false
    private static var marked = false
    private static var long: [[UInt64]] = []
    /// entry、window、content 与最后一圈长任务结束时（busy）。
    private static var stamps: [String: Stamp] = [:]
    /// `settle` 在等内容出来。
    private static var contentShown: CheckedContinuation<Void, Never>?

    private static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func stamp(_ key: String, at time: UInt64) {
        stamps[key] = Stamp(at: time, mainM: threadInstructionsMillions(), allM: instructionsMillions(), cpuMs: mainCPUSeconds(port) * 1000)
    }

    static func start() {
        guard active else { return }
        if DebugScene.defaults.bool(forKey: "CuePadTraceWait") { waitForTracer() }
        woke = now
        stamp("entry", at: woke)
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { woke = now }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { turnEnded() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
        Task { await settle() }
        Task {
            try? await Task.sleep(for: limit)
            report()
        }
    }

    /// 主窗口排上屏（`DebugHooks.present`）。
    static func present(_ window: NSWindow) {
        if active, window is MainShellWindow { presented = true }
    }

    static func mark(_ event: String) {
        if active, event == "cue" || event == "content" { marked = true }
    }

    private static func turnEnded() {
        let end = now
        if end - woke >= longTurn {
            long.append([woke, end])
            stamp("busy", at: end)
        }
        if stamps["window"] == nil, presented { stamp("window", at: end) }
        if stamps["content"] == nil, stamps["window"] != nil, marked {
            stamp("content", at: end)
            contentShown?.resume()
            contentShown = nil
        }
    }

    /// 内容出来后等到连着 `quiet` 没有长任务：睡到最后一圈长任务结束后 `quiet`，其间又有长任务就从它再算。报出这一行、正常退出（收掉起过的子进程）。
    private static func settle() async {
        if stamps["content"] == nil { await withCheckedContinuation { contentShown = $0 } }
        guard let content = stamps["content"] else { return }
        var last = content
        while true {
            try? await Task.sleep(for: .nanoseconds(Int64(last.at + quiet) - Int64(now)))
            guard let busy = stamps["busy"], busy.at > last.at else { break }
            last = busy
        }
        stamps["interactive"] = last
        report()
    }

    private static func report() {
        var row: [String: Any] = ["long": long]
        for key in ["entry", "window", "content", "interactive"] {
            guard let stamp = stamps[key] else { continue }
            row[key] = stamp.at
            row[key + "MainM"] = Int(stamp.mainM.rounded())
            row[key + "AllM"] = Int(stamp.allM.rounded())
            row[key + "CPUMs"] = Int(stamp.cpuMs.rounded())
        }
        print(jsonLine("LAUNCH", row))
        fflush(stdout)
        guard stamps["interactive"] != nil else { exit(1) }
        NSApp.terminate(nil)
    }

    /// 调用它的线程执行的指令（百万）：内核的每线程计数器（`thread_selfcounts`，取指令与周期两项），只在主线程上调。
    private static func threadInstructionsMillions() -> Double {
        var counts: (instructions: UInt64, cycles: UInt64) = (0, 0)
        _ = withUnsafeMutablePointer(to: &counts) { threadSelfCounts(1, $0, MemoryLayout<(UInt64, UInt64)>.size) }
        return Double(counts.instructions) / 1_000_000
    }

    /// 还没进 run loop：同步等信号（`sigwait`），开录之前什么都不做。
    private static func waitForTracer() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGUSR1)
        pthread_sigmask(SIG_BLOCK, &set, nil)
        print("AWAIT trace \(getpid())")
        fflush(stdout)
        var received: Int32 = 0
        sigwait(&set, &received)
    }
}

/// 内核的每线程计数器（xnu `thread_selfcounts`，类型 1 是指令与周期）：SDK 头文件里没有，符号在系统库里，只给测量用。
@_silgen_name("thread_selfcounts")
private func threadSelfCounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32
#endif
