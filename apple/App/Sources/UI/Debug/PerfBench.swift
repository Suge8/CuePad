#if os(macOS) && DEBUG
import AppKit
import CueStore
import CueText
import QuartzCore

/// 界面里的测量点：首屏卡片出现（`content`）、⌘K 拿到结果（`search`）。只在 Debug 构建里由视图调用。
@MainActor
enum PerfProbe {
    private static var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) static var firstSeen: [String: Date] = [:]

    static func mark(_ event: String) {
        if firstSeen[event] == nil { firstSeen[event] = .now }
        waiting.removeValue(forKey: event)?.resume()
    }

    /// 先登记等待，再执行 `trigger`，等到下一次 `event`。
    static func wait(for event: String, after trigger: () -> Void) async {
        await withCheckedContinuation { continuation in
            waiting[event] = continuation
            trigger()
        }
    }
}

/// `-CuePadBench perf`：在当前项目页上依次测冷启动到首屏、滚动、开合纸页、⌘K 搜索与内存，结果作为一行 JSON 打到标准输出后退出。
/// 配合 `-CuePadSeed perf` 生成的大库（第一次运行只写库，之后的运行才是冷启动）。
@MainActor
enum PerfBench {
    static let searchQueries = ["投送", "重试边界", "队列 缓存", "首", "queue", "retry boundary", "the", "api cache"]

    static func run(_ workspace: Workspace) async {
        var result: [String: Any] = [:]
        if PerfProbe.firstSeen["content"] == nil { await PerfProbe.wait(for: "content") {} }
        result["coldStartMs"] = ms(PerfProbe.firstSeen["content"]!.timeIntervalSince(processStart))
        try? await Task.sleep(for: .seconds(2))
        result["memoryAfterStartMB"] = footprintMB()
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        result["scroll"] = await scroll(in: window, view: view)
        result["memoryAfterScrollMB"] = footprintMB()
        result["openCard"] = await openAndClose(workspace, view: view)
        result["sidebar"] = await sidebar(workspace, view: view)
        result["search"] = await search(workspace)
        result["memoryEndMB"] = footprintMB()
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
        NSApp.terminate(nil)
    }

    /// 用滚轮事件把项目页从顶滚到底再滚回顶（每帧 40pt，约 2400pt/s 的快速滚动），记下每帧间隔。
    private static func scroll(in window: NSWindow, view: NSView) async -> [String: Any] {
        let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let recorder = FrameRecorder()
        recorder.start(in: view)
        for direction in [-1, 1] {
            for _ in 0..<240 {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(direction * 40), wheel2: 0, wheel3: 0)
                else { continue }
                event.location = window.convertPoint(toScreen: point)
                if let scroll = NSEvent(cgEvent: event) { window.sendEvent(scroll) }
                await recorder.nextFrame()
            }
        }
        return recorder.stop()
    }

    /// 打开当前项目墙上一张带图的卡（没有就打开最近的卡），记下放大与缩回各 0.8 秒的帧间隔。
    private static func openAndClose(_ workspace: Workspace, view: NSView) async -> [String: Any] {
        let cards = (try? await workspace.services.store.cards(in: workspace.currentProject)) ?? []
        let target = cards.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(40).first { $0.body.contains(CueFormat.imagePrefix) } ?? cards.first
        guard let target else { return [:] }
        let recorder = FrameRecorder()
        recorder.start(in: view)
        workspace.openCard = target.id
        try? await Task.sleep(for: .milliseconds(800))
        let open = recorder.stop()
        try? await Task.sleep(for: .milliseconds(500))
        recorder.start(in: view)
        workspace.openCard = nil
        try? await Task.sleep(for: .milliseconds(800))
        let close = recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))
        return ["open": open, "close": close]
    }

    /// 开合侧栏 times 次、每次 0.6 秒，记下这期间的帧间隔（全部开合合在一起）。
    static func sidebar(_ workspace: Workspace, view: NSView, times: Int = 10) async -> [String: Any] {
        let recorder = FrameRecorder()
        recorder.start(in: view)
        for _ in 0..<times {
            workspace.toggleSidebar()
            try? await Task.sleep(for: .milliseconds(600))
        }
        return recorder.stop()
    }

    /// 每个关键词两段：Store 查询本身（5 次取中位数），以及打开 ⌘K 到结果读到（含面板出现）。
    private static func search(_ workspace: Workspace) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for text in searchQueries {
            var store: [Double] = []
            for _ in 0..<5 {
                let start = Date.now
                _ = try? await workspace.services.store.search(query(text).store(), limit: PaletteQuery.pageSize)
                store.append(ms(Date.now.timeIntervalSince(start)))
            }
            UserDefaults.standard.set(text, forKey: "CuePadSearch")
            let start = Date.now
            await PerfProbe.wait(for: "search") { workspace.overlay = .search }
            let shown = ms(Date.now.timeIntervalSince(start))
            let total = (try? await workspace.services.store.search(query(text).store(), limit: 1).totalCards) ?? -1
            workspace.overlay = nil
            try? await Task.sleep(for: .milliseconds(300))
            rows.append(["query": text, "storeMedianMs": store.sorted()[2], "paletteMs": shown, "hits": total])
        }
        return rows
    }

    private static func query(_ text: String) -> PaletteQuery {
        var query = PaletteQuery()
        query.text = text
        return query
    }

    private static func ms(_ seconds: TimeInterval) -> Double { (seconds * 10_000).rounded() / 10 }

    private static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// 物理内存占用（活动监视器"内存"一栏同口径）。
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576).rounded()
    }
}

/// 用窗口的 display link 记下每一帧的时间戳；帧间隔超过刷新间隔 1.5 倍的算掉帧（按缺了几帧计）。
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    private var waiter: CheckedContinuation<Void, Never>?

    func start(in view: NSView) {
        stamps = []
        let link = view.displayLink(target: self, selector: #selector(tick))
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
#endif
