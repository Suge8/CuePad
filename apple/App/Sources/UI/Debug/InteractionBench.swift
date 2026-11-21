#if os(macOS) && DEBUG
import AppKit
import CueStore
import Darwin
import QuartzCore
import os

/// `-CuePadBench interact`：单次交互那一下的主线程耗时，逐项与预算比较，
/// 每项结果作为一行 `INTERACT {json}` 打到标准输出，量完退出。配 `-CuePadDemo YES`（演示库）或 `-CuePadSeed perf`（大库）。
/// 动作就是点击、快捷键最终调用的工作区方法（`show`、`overlay`、`toggle`；侧栏发主菜单的动作），不经事件投递（那一段只有 1～5ms）。
/// 例外是前台量的"任务气泡开"：真实地点那条任务行（写 `AWAIT click x y`，`perf.py` 经 HID 点，同人点），从松开的那一下起量。
/// 直接调方法时空闲一两秒后的第一下常落在没升频的性能核上（同样的指令点击回合差到一倍）；真实输入进来时系统照人点调度，量的才是用户点的那一下。
/// - **点击回合**：动作发出到画面第一次变（含这次变化的第一帧提交）为止，主线程的全部 CPU 毫秒，跨多圈 run loop 求和：挪到下一帧的活照样算进去，
///   直到画面第一次变（画面的变化看窗口图层树里看得见的层，见 `TurnLog`）；CPU 时间不随机器忙闲变，墙钟会。
/// - **合计、最重一圈、指令数**：动作后 800ms 里主线程 CPU 的总数与最重的一圈（点击回合小而合计大，是活被挪到了后面的帧里，不是没了）；进程执行的指令数（百万）不随机器忙闲变，前后对比以它为准。两端同一份探针与键名（`Probes.swift`）。
/// - **掉帧**：动作后 800ms 内窗口 display link 相邻两次回调间隔超过 1.5 帧的次数与最长一次（毫秒）。
/// 默认在后台量：指令数照样能前后对比，帧与掉帧偏乐观（前台才有玻璃等实际合成）。和预算比要在前台量（`-CuePadForeground YES`，见 `DebugForeground`），
/// 每行的 `foreground` 记这次在不在前台；量完退出，退出时把前台还回去。
enum InteractionBench {
    static let signposter = OSSignposter(logHandle: OSLog(subsystem: AppIdentity.id, category: .pointsOfInterest))
    static let budgets: [String: (clickMs: Double, hitches: Int)] = [
        "页面回访": (14, 1),
        "页面首访": (28, 2),
        "会话页": (90, 2),
        "开编辑页": (28, 2),
        "收编辑页": (14, 2),
        "任务气泡开": (28, 2),
        "任务气泡关": (14, 2),
        "进进展页": (28, 2),
        "看板→项目页": (14, 1),
        "项目页→看板": (14, 1),
        "换项目范围": (28, 2),
        "清项目范围": (28, 2),
        "卡换列": (14, 2),
        "卡回待办": (14, 2),
        "⌘K 面板开": (28, 2),
        "⌘K 面板关": (14, 2),
        "侧栏收起": (28, 2),
        "侧栏展开": (28, 2),
        "Cue 收起": (28, 2),
        "Cue 放回": (28, 2),
        "看板→会话": (90, 2),
        "会话→看板": (28, 2),
        "展开 Cue 面板": (28, 2),
        "收起 Cue 面板": (14, 2),
        "展开任务": (28, 2),
        "收起任务": (14, 2),
        "发送·会话页": (14, 1),
        "发送·Cue 页": (14, 1),
        "接通·Cue 页": (14, 1),
        "在听·Cue 页": (14, 1),
        "挂断·Cue 页": (14, 1),
        "开设置": (28, 2),
        "关设置": (14, 2),
    ]

    private static let turns = TurnLog()
    static let locatesRows = DebugScene.args.driveOpts.bench == "interact"
    static var rows: [AnyHashable: CGRect] = [:]

    static func run(_ workspace: Workspace) async {
        await DebugScene.running("交互测量") { try await measureAll(workspace) }
    }

    private static func measureAll(_ workspace: Workspace) async throws {
        waitForTracer()
        if PerfProbe.firstSeen["content"] == nil { await PerfProbe.wait(for: "content") }
        if DebugScene.args.demo { await DebugScene.seedRemote(workspace.services) }
        // `-CuePadInteractOnly 会话页,开编辑页`：只量这几项，前后对比时省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）
        // Cue 页的对话在等之前写好（库里没有时）：用户点开 Cue 页时对话早在库里
        let only = DebugScene.args.driveOpts.interactOnly.map { Set($0.split(separator: ",").map(String.init)) }
        let measuresCue = only.map { $0.contains("发送·Cue 页") } ?? true
        if measuresCue { await DebugScene.seedCue(workspace.services) }
        await Task.wait(for: .seconds(3))
        guard let window = DebugScene.mainWindow,
              let view = window.contentView
        else { return }
        let borrowed = DebugForeground.borrow(window)
        await Task.wait(for: .seconds(1))
        let foreground = borrowed && NSApp.isActive
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = try await store.sessionPage(SessionQuery(limit: 3)).items.map(\.state.sessionID)
        func step(_ name: String, _ action: () -> Void) async {
            if let only, !only.contains(name) { return }
            let interval = Self.signposter.beginInterval("交互", id: Self.signposter.makeSignpostID(), "\(name, privacy: .public)")
            var row = await measure(name, in: view, action)
            Self.signposter.endInterval("交互", interval)
            row["foreground"] = foreground
            row["freezes"] = PerfProbe.freezes(workspace.services.diagnostics)
            print(jsonLine("INTERACT", row))
            fflush(stdout)
        }
        func click(_ name: String, at point: CGPoint, in view: NSView) async {
            if let only, !only.contains(name) { return }
            let interval = Self.signposter.beginInterval("交互", id: Self.signposter.makeSignpostID(), "\(name, privacy: .public)")
            guard var row = await measureClick(name, at: point, in: view) else {
                print("FAIL \(name)：真实点击 10 秒内没到")
                fflush(stdout)
                return
            }
            Self.signposter.endInterval("交互", interval)
            row["foreground"] = foreground
            row["clicked"] = true
            print(jsonLine("INTERACT", row))
            fflush(stdout)
        }
        await SettingsBench.run(workspace, only: only, step: step)
        let a = projects.indices.contains(1) ? projects[1] : nil, b = projects.indices.contains(2) ? projects[2] : nil
        if let a { await step("页面首访") { workspace.show(.project(a)) } }
        if let b { await step("页面首访") { workspace.show(.project(b)) } }
        if let a, let b {
            for _ in 0..<2 {
                await step("页面回访") { workspace.show(.project(a)) }
                await step("页面回访") { workspace.show(.project(b)) }
            }
        }
        for id in sessions.prefix(2) { await step("会话页") { workspace.show(.session(id)) } }
        let longest = try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: PerfLibrary.longestChat))).items.first
        if let id = longest?.state.sessionID ?? sessions.first, only.map({ $0.contains("发送·会话页") }) ?? true {
            workspace.show(.session(id))
            for _ in 0..<2 {
                workspace.services.settings.setReplyDraft(ComposerDraft(text: sample), for: SessionState.recordID(sessionID: id))
                await step("发送·会话页") { sendShortcut(in: window, field: "回复") }
            }
        }
        if measuresCue {
            for _ in 0..<2 {
                workspace.cue.draft = ComposerDraft(text: sample)
                await step("发送·Cue 页") { sendShortcut(in: window, field: "对 ") }
            }
        }
        if let a { await step("页面回访") { workspace.show(.project(a)) } }
        if let card = try await store.cards(in: workspace.currentProject ?? Project.defaultID).first?.id {
            for _ in 0..<2 {
                await step("开编辑页") { workspace.overlay = .card(card) }
                await step("收编辑页") { workspace.overlay = nil }
            }
        }
        let tasks = try await store.tasks(.inProgress, .todo).flatMap(\.tasks).filter { $0.parentID == nil }
        if let task = tasks.first {
            if only?.contains("任务气泡开") ?? true, workspace.currentProject != task.projectID {
                workspace.show(.project(task.projectID))
                await Task.wait(for: .seconds(1))
            }
            for _ in 0..<2 {
                if foreground, let row = rows[task.id] {
                    await click("任务气泡开", at: screenPoint(of: row, in: window), in: view)
                } else {
                    await step("任务气泡开") { workspace.openTask(task) }
                }
                await step("任务气泡关") { workspace.openTask = nil }
            }
        }
        for _ in 0..<2 {
            await step("进进展页") { workspace.show(.progress) }
            if let a { await step("页面回访") { workspace.show(.project(a)) } }
            await step("⌘K 面板开") { workspace.searching = true }
            await step("⌘K 面板关") { workspace.searching = false }
        }
        if let a {
            workspace.show(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("看板→项目页") { workspace.show(.project(a)) }
                await step("项目页→看板") { workspace.show(.progress) }
                await step("换项目范围") { workspace.projectScope = a }
                await step("清项目范围") { workspace.projectScope = nil }
            }
        }
        if only.map({ $0.contains("卡换列") || $0.contains("卡回待办") }) ?? true, let task = tasks.first(where: { $0.status == .todo }) {
            workspace.show(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("卡换列") { Task { await DebugScene.running("卡换列") { try await store.setStatus(task.id, .done) } } }
                await step("卡回待办") { Task { await DebugScene.running("卡回待办") { try await store.setStatus(task.id, .todo) } } }
            }
        }
        if only.map({ $0.contains("展开任务") || $0.contains("收起任务") }) ?? true,
           let busiest = workspace.catalog?.openTasks.max(by: { $0.value < $1.value })?.key {
            workspace.show(.project(busiest))
            await Task.wait(for: .seconds(2))
            for _ in 0..<2 {
                await step("展开任务") { DebugScene.toggleTaskFold() }
                await step("收起任务") { DebugScene.toggleTaskFold() }
            }
        }
        if let big = workspace.catalog?.summaries.max(by: { $0.value.cardCount < $1.value.cardCount })?.key {
            await step("页面回访") { workspace.show(.project(big)) }
            for _ in 0..<2 {
                await step("侧栏收起") { NSApp.sendAction(#selector(AppDelegate.toggleCueSidebar(_:)), to: nil, from: nil) }
                await step("侧栏展开") { NSApp.sendAction(#selector(AppDelegate.toggleCueSidebar(_:)), to: nil, from: nil) }
                await step("Cue 收起") { workspace.services.settings.cueOpen = false }
                await step("Cue 放回") { workspace.services.settings.cueOpen = true }
            }
        }
        await measureBoard(workspace, sessions: sessions, only: only, step: step)
        try await measureWide(workspace, in: window, sessions: sessions, only: only, foreground: foreground)
        try await measureRelayout(workspace, in: window, sessions: sessions, only: only)
        NSApp.terminate(nil)
    }

    private static let sample = "把重连的用例补上，跑一遍全量测试\n失败的贴给我看，别自己改断言\n做完把覆盖率报一下"

    private static func sendShortcut(in window: NSWindow, field label: String) {
        guard let field = textViews(in: window.contentView).first(where: { $0.accessibilityLabel()?.hasPrefix(label) == true }) else { return }
        let item = NSMenuItem()
        item.tag = ReplyShortcut.send.rawValue
        field.performReplyShortcut(item)
    }

    private static func textViews(in view: NSView?) -> [GrowingTextView] {
        guard let view else { return [] }
        if let field = view as? GrowingTextView { return [field] }
        return view.subviews.flatMap(textViews)
    }

    static func measure(_ name: String, in view: NSView, _ action: () -> Void) async -> [String: Any] {
        await Task.wait(for: .milliseconds(900))
        let recorder = FrameRecorder()
        recorder.start(in: view)
        let instructions = instructionsMillions()
        turns.begin(CACurrentMediaTime(), root: root(of: view))
        action()
        return await finish(name, instructions: instructions, recorder: recorder)
    }

    private static func measureClick(_ name: String, at point: CGPoint, in view: NSView) async -> [String: Any]? {
        await Task.wait(for: .milliseconds(900))
        let recorder = FrameRecorder()
        recorder.start(in: view)
        DebugForeground.movePointer(to: point)
        let release = Release()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if release.instructions == nil {
                release.instructions = instructionsMillions()
                turns.begin(CACurrentMediaTime(), root: root(of: view))
                release.resume()
            }
            return event
        }
        await withCheckedContinuation { waiter in
            release.waiter = waiter
            print("AWAIT click \(Int(point.x.rounded())) \(Int(point.y.rounded()))")
            fflush(stdout)
            Task {
                await Task.wait(for: Self.clickLimit)
                release.resume()
            }
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        guard let instructions = release.instructions else {
            _ = recorder.stop()
            return nil
        }
        return await finish(name, instructions: instructions, recorder: recorder)
    }

    private static let clickLimit: Duration = .seconds(10)

    private final class Release {
        var instructions: Double?
        var waiter: CheckedContinuation<Void, Never>?

        func resume() {
            waiter?.resume()
            waiter = nil
        }
    }

    private static func root(of view: NSView) -> CALayer? { view.window?.contentView?.superview?.layer ?? view.layer }

    private static func screenPoint(of row: CGRect, in window: NSWindow) -> CGPoint {
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
        return CGPoint(x: window.frame.minX + row.minX + TaskMetrics.ringColumn + Self.titleInset, y: top + row.midY)
    }

    private static let titleInset: CGFloat = 30

    private static func finish(_ name: String, instructions: Double, recorder: FrameRecorder) async -> [String: Any] {
        await Task.wait(for: .milliseconds(800))
        var row = TurnLog.metrics(turns.finish(), instructions: instructions, frames: recorder.stop())
        row["name"] = name
        row["budgetClickMs"] = budgets[name]?.clickMs ?? 0
        row["budgetHitches"] = budgets[name]?.hitches ?? 0
        return row
    }
}
#endif
