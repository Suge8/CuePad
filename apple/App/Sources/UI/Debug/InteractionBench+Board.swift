#if os(macOS) && DEBUG
import AppKit
import CueStore

/// 看板这一页上的几下（`-CuePadBench interact`，宽屏阈值之前），按 `measure` 的口径量一轮点按：
/// - 看板⇄会话：从看板开一个会话（会话条从图标条换成宽版、主区换成会话页）、再点会话条的"进展"回来（会话条收回图标条），走点击的同一条路（`openSession`、`selectPane`）。
///   会话条按正式版的默认摆（看板上图标条、别处宽版，`WideMetrics` 头注释），这一下换宽是用户真看得到的那一下。
/// - 列宽换档：一下只改一处（一个会话开始或停下、一张卡点一次完成圈），让一列在有卡与空之间换档（`BoardWidths`），别的列的宽跟着变、卡跟着折行，列宽与卡一起滑：
///   - 推进中空着时（大库）：全部项目都在看板上，待办、已完成长到能滚，各列的阅读位置验得了；量的是一个会话开始干活（推进中有了一张会话卡）、再停下（推进中空了），
///     各是会话状态的一次写入（`PiStateRecorder`，同 Mac 上的会话报上来）。推进中只收活的会话（`CueTally`），所以换档用会话、不用把待办标成进行中。
///   - 推进中有卡时（演示库）：看板只看待办最多的那个项目，开量前（不计在内）先把它别的待办做完、只留一件；量的是这一件做完（待办空了）、再打开，量完放回待办。
///     列都短，阅读位置验不了（同宽屏阈值那几项的演示库），只验换没换宽。
///   写库是异步的，同"卡换列"：画面在库变了、看板重读之后才动。行里另记：`laneShift` 是这一下列宽真的换了（看板各列的宽前后不同），
///   `page` 是看板每一列滚到中段的那张卡还在眼前（`WidePage`，只看主区：换档不碰 Cue 那一栏）；没换宽、没保住，`perf-mac.sh` 判失败。
/// - Cue 面板：点 Cue 栏头头像那一块开合（`CueTitle` 交出的同一个开关，`debugExposesCuePanel`），与 iOS 那两项同名。
extension InteractionBench {
    static func measureBoard(
        _ workspace: Workspace, in view: NSView, sessions: [String], only: Set<String>?,
        step: (String, NSView?, (inout [String: Any]) async -> Void, () -> Void) async -> Void
    ) async throws {
        func wants(_ names: String...) -> Bool { only.map { !$0.isDisjoint(with: names) } ?? true }
        let settings = workspace.services.settings
        settings.railExpanded = true
        settings.boardRailExpanded = false
        settings.cueOpen = true
        if wants("看板→会话", "会话→看板"), let session = sessions.first {
            workspace.selectPane(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("看板→会话", nil, { _ in }) { workspace.openSession(PiSessionState.recordID(sessionID: session), sessionID: session) }
                await step("会话→看板", nil, { _ in }) { workspace.selectPane(.progress) }
            }
        }
        if wants("列宽换档·列空", "列宽换档·有卡") {
            try await measureLanes(workspace, in: view, step: step)
        }
        if wants("展开 Cue 面板", "收起 Cue 面板") {
            workspace.selectPane(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("展开 Cue 面板", nil, { _ in }) { DebugScene.toggleCuePanel() }
                await step("收起 Cue 面板", nil, { _ in }) { DebugScene.toggleCuePanel() }
            }
        }
    }

    /// 系统的悬浮滚动条停手后多久淡完（亮着约 1 秒，再淡约 0.25 秒），留出余量。
    private static let scrollerFade: Duration = .seconds(2)

    /// 列宽换档那两项（头注释）。
    private static func measureLanes(
        _ workspace: Workspace, in view: NSView, step: (String, NSView?, (inout [String: Any]) async -> Void, () -> Void) async -> Void
    ) async throws {
        let store = workspace.services.store
        let board = try await TaskBoard.read(from: store)
        workspace.selectPane(.progress)
        // 每一步：这一项的名字与那一次写入，两步来回；量完收拾
        let steps: [(String, @Sendable () async throws -> Void)], cleanup: () async throws -> Void
        if board.advancing.isEmpty {
            let recorder = DebugScene.demoRecorder(store, minInterval: .zero)
            let session = "lane-bench"
            workspace.projectScope = nil
            steps = [
                ("列宽换档·有卡", { _ = try await recorder.update(sessionID: session, state: .thinking, title: "lane") }),
                ("列宽换档·列空", { _ = try await recorder.update(sessionID: session, state: .ended, title: "lane") }),
            ]
            cleanup = {}
        } else {
            let groups = Dictionary(grouping: board.todo.map(\.task), by: \.projectID)
            guard let (project, tasks) = groups.max(by: { $0.value.count < $1.value.count }), let task = tasks.last?.id else { throw DebugScene.Unmet("看板上没有待办") }
            let restore = tasks.dropLast().map(\.id)
            for id in restore { try await store.setStatus(id, .done) }
            workspace.projectScope = project
            steps = [
                ("列宽换档·列空", { try await store.setStatus(task, .done) }),
                ("列宽换档·有卡", { try await store.setStatus(task, .todo) }),
            ]
            cleanup = { for id in restore { try await store.setStatus(id, .todo) } }
        }
        await Task.wait(for: .seconds(1.5))
        for _ in 0..<2 {
            for (name, write) in steps {
                let columns = wideColumns(in: view).filter { $0.slot == .main }
                await WidePage.scrollToMiddle(columns)
                // 滚过的列的系统滚动条约 1 秒后自己淡掉（AppKit 改图层的不透明度）：等它淡完再量，不然量到的"画面第一次变"是它，不是换档
                await Task.wait(for: Self.scrollerFade)
                let page = WidePage(columns), main = columns.first { $0.slot == .main }
                let before = main.map(WidePage.widths) ?? []
                // 一次写库会话条（大库里新开的会话）可能比看板先读到：点击回合只看主区，量到的是看板换档那一下
                await step(name, main, { row in
                    let after = wideColumns(in: view).filter { $0.slot == .main }
                    let widths = after.first { $0.slot == .main }.map(WidePage.widths) ?? []
                    let shown = page.compare(after)
                    row["laneShift"] = widths != before
                    row["laneWidths"] = [before, widths]
                    row["page"] = shown.verdict.rawValue
                    row["pageUntested"] = page.untested
                    row["pages"] = shown.detail
                }) { Task { await DebugScene.running(name) { try await write() } } }
            }
        }
        try await cleanup()
        workspace.projectScope = nil
    }
}
#endif
