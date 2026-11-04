#if os(macOS) && DEBUG
import AppKit
import CueStore

/// 看板这一页上的几下（`-CuePadBench interact`，宽屏阈值之前），按 `measure` 的口径量一轮点按：
/// - 看板⇄会话：从看板开一个会话（会话条从图标条换成宽版、主区换成会话页）、再点会话条的"进展"回来（会话条收回图标条），走点击的同一条路（`openSession`、`selectPane`）。
///   会话条按正式版的默认摆（看板上图标条、别处宽版，`WideMetrics` 头注释），这一下换宽是用户真看得到的那一下。
/// - 列宽换档：看板只看待办最少的那个项目（项目范围），把它的待办都做完、再都打开：待办那一列在空与有卡之间换档（`BoardWidths`），列宽跟着卡一起滑。
///   写库是异步的，同"卡换列"：画面在库变了、看板重读之后才动。
/// - Cue 面板：点 Cue 栏头头像那一块开合（`CueTitle` 交出的同一个开关，`debugExposesCuePanel`），与 iOS 那两项同名。
extension InteractionBench {
    static func measureBoard(
        _ workspace: Workspace, sessions: [String], only: Set<String>?, step: (String, () -> Void) async -> Void
    ) async throws {
        func wants(_ names: String...) -> Bool { only.map { !$0.isDisjoint(with: names) } ?? true }
        let settings = workspace.services.settings
        let store = workspace.services.store
        settings.railExpanded = true
        settings.boardRailExpanded = false
        settings.cueOpen = true
        if wants("看板→会话", "会话→看板"), let session = sessions.first {
            workspace.selectPane(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("看板→会话") { workspace.openSession(PiSessionState.recordID(sessionID: session), sessionID: session) }
                await step("会话→看板") { workspace.selectPane(.progress) }
            }
        }
        if wants("列宽换档·列空", "列宽换档·有卡") {
            let todo = try await TaskBoard.read(from: store).todo.map(\.task)
            let counts = Dictionary(grouping: todo, by: \.projectID)
            guard let (project, tasks) = counts.min(by: { $0.value.count < $1.value.count }) else { throw DebugScene.Unmet("看板上没有待办") }
            let ids = tasks.map(\.id)
            workspace.selectPane(.progress)
            workspace.projectScope = project
            await Task.wait(for: .seconds(1))
            func set(_ status: TaskStatus) { Task { await DebugScene.running("列宽换档") { for id in ids { try await store.setStatus(id, status) } } } }
            for _ in 0..<2 {
                await step("列宽换档·列空") { set(.done) }
                await step("列宽换档·有卡") { set(.todo) }
            }
            workspace.projectScope = nil
        }
        if wants("展开 Cue 面板", "收起 Cue 面板") {
            workspace.selectPane(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("展开 Cue 面板") { DebugScene.toggleCuePanel() }
                await step("收起 Cue 面板") { DebugScene.toggleCuePanel() }
            }
        }
    }
}
#endif
