#if os(macOS) && DEBUG
import AppKit
import CueStore
import os

/// `-CuePadBench scenarios`（配 `-CuePadSeed perf` 的大库，库里的会话最好先用 `scripts/pi-live.py` 连到桥上）：
/// 按用户操作逐项量帧间隔，每一项包在一段 os_signpost（PointsOfInterest，名 `scenario`、消息为场景名）里，
/// 给 Instruments 的 SwiftUI / Animation Hitches / Time Profiler 录制按场景切时间窗；结果作为一行 JSON 打到标准输出后退出。
/// `-CuePadScenario a,b` 只跑列出的（默认全部）：
/// - `projects`：侧栏切项目（每个 0.45 秒，前 16 个来回两轮）；
/// - `agentScroll`：Agent 整页滚轮往下再往上；
/// - `chatOpen`：来回打开几个长短不一的会话；
/// - `chatScroll`：最长的会话往上翻到顶再回到底；
/// - `chatStream`：会话在线忙着时，每 0.4 秒进来一条带工具活动的回答（贴着最新）；
/// - `typing`：回复框里按 15 字/秒打 90 个字；
/// - `hoverProject`、`hoverAgent`、`hoverChat`：真实指针在项目页卡片墙、Agent 整页、最长会话的对话里来回扫（会动真实指针，窗口要在屏幕上）；`hoverChat` 另报悬停进出的次数（`hoverToggles`），正常是个位数到几百，几千就是来回翻转的循环；
/// - `hoverSidebar`、`sidebarScroll`：指针在侧栏里来回扫（项目行、底部 Agent 区）；侧栏项目列表用滚轮往下再往上；
/// - `resize`：在项目页、Agent 整页、会话页各把窗口宽度从 1440 逐帧缩到 900 再拉回；
/// - `search`：⌘K 里逐字打一个关键词。
@MainActor
enum ScenarioBench {
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: "com.sugeh.cuepad.perf", category: .pointsOfInterest))
    private static let all = ["projects", "agentScroll", "chatOpen", "chatScroll", "chatStream", "typing", "hoverProject", "hoverAgent", "hoverChat", "hoverSidebar", "sidebarScroll", "resize", "search"]

    static func run(_ workspace: Workspace) async {
        if PerfProbe.firstSeen["content"] == nil { await PerfProbe.wait(for: "content") {} }
        try? await Task.sleep(for: .seconds(6))
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        let names = UserDefaults.standard.string(forKey: "CuePadScenario")?.split(separator: ",").map(String.init) ?? all
        let bench = Run(workspace: workspace, window: window, view: view)
        var result: [String: Any] = [:]
        for name in names {
            result[name] = await bench.measure(name)
            try? await Task.sleep(for: .milliseconds(500))
        }
        result["memoryEndMB"] = PerfBench.footprintMB()
        print("PERF " + String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        NSApp.terminate(nil)
    }

    private static var hoverTogglesSeen = 0
    private static var scrolledUp = 0.0

    @MainActor
    private struct Run {
        let workspace: Workspace
        let window: NSWindow
        let view: NSView
        var store: CueStore { workspace.services.store }

        func measure(_ name: String) async -> [String: Any] {
            let recorder = FrameRecorder()
            recorder.start(in: view)
            let state = signposter.beginInterval("scenario", id: signposter.makeSignpostID(), "\(name)")
            let started = Date.now
            switch name {
            case "projects": await projects()
            case "agentScroll": await agentScroll()
            case "chatOpen": await chatOpen()
            case "chatScroll": await chatScroll()
            case "chatStream": await chatStream()
            case "typing": await typing()
            case "hoverProject": await hoverProject()
            case "hoverAgent": await hoverAgent()
            case "hoverChat": await hoverChat()
            case "hoverSidebar": await hoverSidebar()
            case "sidebarScroll": await sidebarScroll()
            case "resize": await resize()
            case "search": await search()
            default: break
            }
            signposter.endInterval("scenario", state)
            var row = recorder.stop()
            row["seconds"] = (Date.now.timeIntervalSince(started) * 10).rounded() / 10
            row["hitchesAt"] = nil
            if name == "hoverChat" { row["hoverToggles"] = ScenarioBench.hoverTogglesSeen }
            if name == "chatScroll" { row["scrolledUpPt"] = ScenarioBench.scrolledUp }
            return row
        }

        // MARK: 场景

        func projects() async {
            let ids = (workspace.catalog?.projects ?? []).prefix(16).map(\.id)
            for _ in 0..<2 {
                for id in ids {
                    workspace.show(.project(id))
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
        }

        func agentScroll() async {
            workspace.show(.agent)
            try? await Task.sleep(for: .seconds(1))
            await scrollWheel(frames: 300, directions: [-1, 1])
        }

        func chatOpen() async {
            for id in await chats().prefix(6) + (await chats().suffix(3)) {
                workspace.show(.agent)
                try? await Task.sleep(for: .milliseconds(300))
                workspace.show(.session(id))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }

        func chatScroll() async {
            guard let id = await chats().last else { return }
            workspace.show(.session(id))
            try? await Task.sleep(for: .seconds(1))
            // 指针停在对话底部那条你的话的气泡上（第一格滚动就让一块文字落到指针底下）：悬停选择曾在这里来回翻转、把主线程占死
            park(x: 0.6, y: 0.8)
            await scrollWheel(frames: 300, directions: [1])
            ScenarioBench.scrolledUp = distanceFromBottom()
            await scrollWheel(frames: 300, directions: [-1])
        }

        func chatStream() async {
            guard let id = await chats().last else { return }
            workspace.show(.session(id))
            try? await Task.sleep(for: .seconds(1))
            let base = Int64(Date.now.timeIntervalSince1970 * 1000)
            for index in 0..<20 {
                let text = "流式进来的第 \(index) 条：" + String(repeating: "这一段用来撑长，看贴着最新时的滚动跟随。", count: 3 + index % 4)
                let at = Date.now
                let message = PiChatMessage(
                    sessionID: id, entryID: "stream-\(base)-\(index)", seq: base + Int64(index), role: .pi, text: text, at: at,
                    tools: .init(edits: 1, reads: 2, items: [.init(kind: .edit, target: "src/stream.swift", added: 3, removed: 1), .init(kind: .read, target: "docs/a.md")]),
                    roundStartedAt: at.addingTimeInterval(-30))
                try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: [message], recap: PiRecap(lastReply: text)))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        func typing() async {
            guard let id = await chats().dropFirst(8).first else { return }
            workspace.show(.session(id))
            try? await Task.sleep(for: .seconds(1.5))
            guard let field = editableText() else { return }
            window.makeFirstResponder(field)
            let text = Array("下一步先把重试边界和投送队列的缓存问题查清楚然后再决定要不要改动编辑器里的变量模板同步逻辑，我们需要确认性能不会回退")
            for character in text.prefix(90) {
                field.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(66))
            }
            field.string = ""
            field.didChangeText()
        }

        func hoverProject() async {
            workspace.show(.project((workspace.catalog?.projects ?? []).first?.id ?? UUID()))
            try? await Task.sleep(for: .seconds(1.5))
            await sweep(rows: 14, columns: 6)
        }

        func hoverAgent() async {
            workspace.show(.agent)
            try? await Task.sleep(for: .seconds(1.5))
            await sweep(rows: 30, columns: 2)
        }

        /// 侧栏（项目行与底部的 Agent 区）：停在项目页上，指针在侧栏里来回扫。
        func hoverSidebar() async {
            workspace.show(.project((workspace.catalog?.projects ?? []).first?.id ?? UUID()))
            try? await Task.sleep(for: .seconds(1.5))
            await sweep(rows: 30, columns: 1, xs: 0.03...0.15)
        }

        /// 侧栏的项目列表（50 个项目）用滚轮往下再往上。
        func sidebarScroll() async {
            workspace.show(.project((workspace.catalog?.projects ?? []).first?.id ?? UUID()))
            try? await Task.sleep(for: .seconds(1.5))
            _ = await PerfBench.scroll(in: window, view: view, directions: [-1, 1], frames: 150, atX: 0.08)
        }

        func hoverChat() async {
            guard let id = await chats().last else { return }
            workspace.show(.session(id))
            try? await Task.sleep(for: .seconds(1.5))
            DebugScene.hoverToggles = 0
            await sweep(rows: 14, columns: 3)
            ScenarioBench.hoverTogglesSeen = DebugScene.hoverToggles
        }

        func resize() async {
            let original = window.frame
            for page in [Workspace.Page.project((workspace.catalog?.projects ?? []).first?.id ?? UUID()), .agent, .session(await chats().dropFirst(8).first ?? "")] {
                workspace.show(page)
                try? await Task.sleep(for: .seconds(1.2))
                let recorder = FrameRecorder()
                recorder.start(in: view)
                for width in Array(stride(from: original.width, through: 900, by: -10)) + Array(stride(from: 900, through: original.width, by: 10)) {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                    await recorder.nextFrame()
                }
                _ = recorder.stop()
            }
            window.setFrame(original, display: true)
        }

        func search() async {
            workspace.searching = true
            try? await Task.sleep(for: .milliseconds(500))
            guard let field = editableText() else { return }
            for character in "retry boundary 队列" {
                field.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(120))
            }
            workspace.searching = false
        }

        // MARK: 工具

        /// 有对话的会话，对话短的在前。
        func chats() async -> [String] {
            var rows: [(String, Int)] = []
            for item in (try? await store.piSessionPage(PiSessionQuery(limit: 400)).items) ?? [] {
                let count = (try? await store.piMessages(of: item.state.sessionID).count) ?? 0
                if count > 0 { rows.append((item.state.sessionID, count)) }
            }
            return rows.sorted { $0.1 < $1.1 }.map(\.0)
        }

        /// 内容区里最高的那个滚动区，可见区底边离内容末端多远。
        func distanceFromBottom() -> Double {
            var queue: [NSView] = [view]
            var best: NSScrollView?
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let scroll = next as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
                queue += next.subviews
            }
            guard let best, let document = best.documentView else { return -1 }
            return (document.frame.height - best.documentVisibleRect.maxY).rounded()
        }

        /// 真实指针停到窗口里的这一点（占窗口宽高的比例）。
        func park(x: Double, y: Double) {
            let frame = window.frame
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
            let point = CGPoint(x: frame.minX + frame.width * x, y: top + frame.height * y)
            CGWarpMouseCursorPosition(point)
            // 瞬移不产生鼠标事件，窗口不知道指针到了哪：补一个移动事件
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        func editableText() -> NSTextView? {
            if let field = window.firstResponder as? NSTextView, field.isEditable { return field }
            var queue: [NSView] = [view]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let field = next as? NSTextView, field.isEditable { return field }
                queue += next.subviews
            }
            return nil
        }

        func scrollWheel(frames: Int, directions: [Int]) async {
            _ = await PerfBench.scroll(in: window, view: view, directions: directions, frames: frames)
        }

        /// 真实指针在内容区里蛇形来回扫，每帧移一步。
        func sweep(rows: Int, columns: Int, xs: ClosedRange<Double> = 0.3...0.9) async {
            NSApp.activate()
            let bounds = window.frame
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.maxY
            let recorder = FrameRecorder()
            recorder.start(in: view)
            let steps = 40
            for row in 0..<rows {
                for column in 0..<columns * steps {
                    let phase = Double(column) / Double(steps)
                    let x = bounds.minX + bounds.width * (xs.lowerBound + (xs.upperBound - xs.lowerBound) * (row.isMultiple(of: 2) ? phase / Double(columns) : 1 - phase / Double(columns)))
                    let y = top + 120 + (bounds.height - 260) * Double(row) / Double(rows)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
                    await recorder.nextFrame()
                }
            }
            _ = recorder.stop()
        }
    }
}
#endif
