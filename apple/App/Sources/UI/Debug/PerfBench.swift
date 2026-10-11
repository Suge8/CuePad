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

    /// 忘掉 `event` 的首次时间，下一次 `mark` 重新记。
    static func reset(_ event: String) { firstSeen[event] = nil }

    /// 先登记等待，再执行 `trigger`，等到下一次 `event`；给了 `timeout`（秒）时最多等这么久。
    static func wait(for event: String, timeout: TimeInterval? = nil, after trigger: () -> Void) async {
        await withCheckedContinuation { continuation in
            waiting[event] = continuation
            if let timeout {
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    waiting.removeValue(forKey: event)?.resume()
                }
            }
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

    /// `-CuePadBench agent`：打开 Agent 整页，用滚轮一路往下滚（每帧 40pt，读到底会接着读下一页），记下帧间隔、用时与内存，
    /// 结果作为一行 JSON 打到标准输出后退出。用真实大库（几千条历史）测分页与长列表。
    static func agent(_ workspace: Workspace) async {
        workspace.show(.agent)
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        var result: [String: Any] = ["memoryBeforeMB": footprintMB()]
        let started = Date.now
        result["scrollDown"] = await scroll(in: window, view: view, directions: [-1], frames: agentFrames)
        result["scrollSeconds"] = (Date.now.timeIntervalSince(started) * 10).rounded() / 10
        result["memoryAfterMB"] = footprintMB()
        result["scrollUp"] = await scroll(in: window, view: view, directions: [1], frames: 240)
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
        NSApp.terminate(nil)
    }

    /// 往下滚的帧数：按一行约 70pt，够把三千多条历史滚到底。
    private static let agentFrames = 6000

    /// 用滚轮事件把项目页从顶滚到底再滚回顶（每帧 40pt，约 2400pt/s 的快速滚动），记下每帧间隔。
    static func scroll(in window: NSWindow, view: NSView, directions: [Int] = [-1, 1], frames: Int = 240, atX: Double = 0.5) async -> [String: Any] {
        // CGEvent 的位置是全局坐标、原点在主屏左上；窗口换算出来的屏幕坐标原点在左下，要翻一下，否则事件落不到内容区中间
        let onScreen = window.convertPoint(toScreen: CGPoint(x: view.bounds.width * atX, y: view.bounds.midY))
        let location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.y)
        let target = view.hitTest(CGPoint(x: view.bounds.width * atX, y: view.bounds.midY))
        let recorder = FrameRecorder()
        recorder.start(in: view)
        // -CuePadWheel trackpad：像触控板那样带手势阶段（开始、变化、结束）；默认是没有阶段的滚轮（普通鼠标）
        let trackpad = UserDefaults.standard.string(forKey: "CuePadWheel") == "trackpad"
        for direction in directions {
            for frame in 0..<frames {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(direction * 40), wheel2: 0, wheel3: 0)
                else { continue }
                if trackpad {
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: frame == 0 ? 1 : frame == frames - 1 ? 4 : 2)
                }
                event.location = location
                // 直接交给内容区中间那块视图（后台窗口的 sendEvent 不保证落到滚动区），它沿响应链交给所在的滚动区
                if let scroll = NSEvent(cgEvent: event) { target?.scrollWheel(with: scroll) }
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
            DebugScene.searchOverride = text
            let start = Date.now
            await PerfProbe.wait(for: "search") { workspace.searching = true }
            let shown = ms(Date.now.timeIntervalSince(start))
            let total = (try? await workspace.services.store.search(query(text).store(), limit: 1).totalCards) ?? -1
            workspace.searching = false
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

    static func ms(_ seconds: TimeInterval) -> Double { (seconds * 10_000).rounded() / 10 }

    private static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// 物理内存占用（活动监视器"内存"一栏同口径）。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576).rounded()
    }
}
#endif
