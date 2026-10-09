#if os(macOS) && DEBUG
import AppKit
import CueStore

/// `-CuePadBench switch`（配真实库副本）：切会话的耗时与对话区是否空白，结果作为一行 JSON 打到标准输出后退出。
/// 会话取对话最长与最短的交替（`-CuePadSwitchCount N`，默认 12；`-CuePadSwitchOnly 33,18` 改为只量这几个消息条数的会话各 3 遍），
/// 每三个中有一个先回 Agent 整页再点进。`-CuePadSwitchPass open|ink` 只跑其中一遍：
/// - `open`：点开后 0.7 秒的帧间隔（口径同 `PerfBench`）与"对话排出来"（`conversation` 探针）用时；
/// - `ink`：每帧截一次对话区量"第一次看得见内容"的用时，0.7 秒后再截一次；还是空白就是"页面空白、要往上滑才显示"；
///   再写进一条新回答，看贴着最新时是否跟上；另有"还没对话的老会话、点开后整批对话才到"与"滚轮往上翻到顶"两项。
/// 空白只在会话在线（桥上连着）时出现，复现要先用 `scripts/pi-live.py` 把这些会话连上桥（`CUEPAD_PI_SOCKET_DIR` 同一目录）。
/// `-CuePadSwitchShots <目录>` 把每次的窗口内容存成 PNG。
@MainActor
enum SwitchBench {
    /// 对话区里"不是底色"的像素占比低于它算空白（有一屏对话时通常在 3% 以上）。
    private static let blankBelow = 0.003
    private static let defaults = UserDefaults.standard

    static func run(_ workspace: Workspace) async {
        workspace.show(.agent)
        // 桥上的在线会话要几秒才连上
        try? await Task.sleep(for: .seconds(6))
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        let store = workspace.services.store
        var chats: [(id: String, count: Int)] = []
        var empty: [String] = []
        for item in (try? await store.piSessionPage(PiSessionQuery(limit: 400)).items) ?? [] {
            let count = (try? await store.piMessages(of: item.state.sessionID).count) ?? 0
            if count > 0 { chats.append((item.state.sessionID, count)) } else { empty.append(item.state.sessionID) }
        }
        chats.sort { $0.count > $1.count }
        let plan = plan(chats)
        let pass = defaults.string(forKey: "CuePadSwitchPass")
        var result: [String: Any] = ["sessions": plan.map(\.count), "liveSessions": workspace.services.pi.sessions.count]
        if pass != "ink" { result["open"] = await open(plan, workspace, view) }
        if pass != "open" {
            let ink = await ink(plan, workspace, view)
            let late = await lateTranscript(Array(empty.sorted().prefix(6)), workspace, view)
            result["ink"] = ink
            result["lateTranscript"] = late
            result["scrollUp"] = await scrollUp(Array(plan.prefix(2)), workspace, window, view)
            result["blankCount"] = (ink + late).filter { $0["blank"] as? Bool == true }.count
        }
        result["memoryEndMB"] = PerfBench.footprintMB()
        print("PERF " + String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        NSApp.terminate(nil)
    }

    private static func plan(_ chats: [(id: String, count: Int)]) -> [(id: String, count: Int)] {
        if let only = defaults.string(forKey: "CuePadSwitchOnly") {
            let counts = Set(only.split(separator: ",").compactMap { Int($0) })
            return Array(repeating: chats.filter { counts.contains($0.count) }, count: 3).flatMap { $0 }
        }
        let count = defaults.integer(forKey: "CuePadSwitchCount")
        return (0..<min(chats.count, count == 0 ? 12 : count)).map { index in
            index.isMultiple(of: 2) ? chats[index / 2] : chats[chats.count - 1 - index / 2]
        }
    }

    /// 点开第 `index` 个会话：每三个中有一个先回 Agent 整页。
    private static func prepare(_ index: Int, _ workspace: Workspace) async {
        guard index % 3 == 2 else { return }
        workspace.show(.agent)
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func open(_ plan: [(id: String, count: Int)], _ workspace: Workspace, _ view: NSView) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (index, session) in plan.enumerated() {
            await prepare(index, workspace)
            PerfProbe.reset("conversation")
            let recorder = FrameRecorder()
            recorder.start(in: view)
            let started = Date.now
            await PerfProbe.wait(for: "conversation", timeout: 3) { workspace.show(.session(session.id)) }
            let shown = PerfProbe.firstSeen["conversation"].map { PerfBench.ms($0.timeIntervalSince(started)) } ?? -1
            try? await Task.sleep(for: .milliseconds(700))
            var row = recorder.stop()
            row["messages"] = session.count
            row["conversationMs"] = shown
            rows.append(row)
        }
        return rows
    }

    private static func ink(_ plan: [(id: String, count: Int)], _ workspace: Workspace, _ view: NSView) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (index, session) in plan.enumerated() {
            await prepare(index, workspace)
            let recorder = FrameRecorder()
            recorder.start(in: view)
            let started = Date.now
            workspace.show(.session(session.id))
            var first = -1.0
            while first < 0, Date.now.timeIntervalSince(started) < 2 {
                await recorder.nextFrame()
                if inkShare(of: view) > blankBelow { first = PerfBench.ms(Date.now.timeIntervalSince(started)) }
            }
            _ = recorder.stop()
            try? await Task.sleep(for: .milliseconds(700))
            let settled = inkShare(of: view)
            snapshot(of: view, name: "\(index)-\(session.count)")
            // 再来一条新回答：贴着最新时应跟上去
            await appendReply("新到的回答：" + String(repeating: "这一段用来把对话撑长，看滚动跟随。", count: 6), to: session.id, workspace)
            try? await Task.sleep(for: .milliseconds(700))
            let appended = inkShare(of: view)
            let following = isAtNewest(view)
            rows.append([
                "messages": session.count, "firstInkMs": first, "inkPercentAfter700ms": percent(settled),
                "blank": settled <= blankBelow || appended <= blankBelow || !following,
                "blankAtOpen": settled <= blankBelow, "blankAfterAppend": appended <= blankBelow, "atNewestAfterAppend": following,
            ])
        }
        return rows
    }

    /// 还没有对话的老会话：点开后整批对话才到（Mac 补写），内容从一小段长到很高。
    private static func lateTranscript(_ sessions: [String], _ workspace: Workspace, _ view: NSView) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for id in sessions {
            workspace.show(.agent)
            try? await Task.sleep(for: .milliseconds(400))
            workspace.show(.session(id))
            await DebugScene.bulkChat(id, count: 30, store: workspace.services.store)
            try? await Task.sleep(for: .milliseconds(900))
            let shown = inkShare(of: view)
            snapshot(of: view, name: "late-\(id)")
            rows.append(["inkPercent": percent(shown), "blank": shown <= blankBelow || !isAtNewest(view)])
        }
        return rows
    }

    /// 往上翻：用滚轮翻到最上面（用户在滚，排开的几条不自动多排）：最上面是"显示更早的"一行，可见区不空白。
    private static func scrollUp(
        _ plan: [(id: String, count: Int)], _ workspace: Workspace, _ window: NSWindow, _ view: NSView
    ) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for session in plan {
            workspace.show(.agent)
            try? await Task.sleep(for: .milliseconds(400))
            workspace.show(.session(session.id))
            try? await Task.sleep(for: .milliseconds(900))
            let before = conversationScroll(view)?.documentView?.frame.height ?? 0
            var frames = await PerfBench.scroll(in: window, view: view, directions: [1], frames: 150)
            frames["hitchesAt"] = nil
            try? await Task.sleep(for: .milliseconds(500))
            snapshot(of: view, name: "top-\(session.count)")
            rows.append([
                "messages": session.count, "heightBefore": before.rounded(), "frames": frames,
                "heightAfter": (conversationScroll(view)?.documentView?.frame.height ?? 0).rounded(), "inkPercent": percent(inkShare(of: view)),
            ])
        }
        return rows
    }

    private static func appendReply(_ text: String, to id: String, _ workspace: Workspace) async {
        let message = PiChatMessage(sessionID: id, entryID: UUID().uuidString, seq: Int64(Date.now.timeIntervalSince1970 * 1000), role: .pi, text: text, at: .now)
        try? await workspace.services.store.writePiTranscript(PiTranscript(sessionID: id, messages: [message], recap: PiRecap(lastReply: text)))
    }

    private static func percent(_ share: Double) -> Double { (share * 1000).rounded() / 10 }

    /// 对话的滚动区：窗口里比整窗矮、又不是代码块那种小滚动区的那一个。
    private static func conversationScroll(_ view: NSView) -> NSScrollView? {
        var found: NSScrollView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.frame.width > 400, scroll.frame.height > 300, scroll.frame.height < view.bounds.height { found = scroll }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private static func isAtNewest(_ view: NSView) -> Bool {
        guard let scroll = conversationScroll(view), let document = scroll.documentView else { return false }
        return scroll.documentVisibleRect.maxY >= document.frame.height - 24
    }

    private static func snapshot(of view: NSView, name: String) {
        guard let dir = defaults.string(forKey: "CuePadSwitchShots"), let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(dir)/\(name).png"))
    }

    /// 窗口右侧对话区（避开侧栏、工具栏与底部回复框）里与底色不同的像素占比。
    private static func inkShare(of view: NSView) -> Double {
        let bounds = view.bounds
        let band = CGRect(x: bounds.width * 0.45, y: 70, width: bounds.width * 0.5, height: max(0, bounds.height - 70 - 100))
        guard band.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: band) else { return 0 }
        view.cacheDisplay(in: band, to: rep)
        guard let data = rep.bitmapData else { return 0 }
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let at = y * rep.bytesPerRow + x * rep.samplesPerPixel
                // 每通道取高 5 位：抗锯齿与渐隐不把底色拆成很多种
                counts[UInt32(data[at] >> 3) << 10 | UInt32(data[at + 1] >> 3) << 5 | UInt32(data[at + 2] >> 3), default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let background = counts.values.max() else { return 0 }
        return Double(total - background) / Double(total)
    }
}
#endif
