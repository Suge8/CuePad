#if os(macOS) && DEBUG
import AppKit
import CueStore

/// 看板这一页上的几下（`-CuePadBench interact`，宽屏阈值之前），按 `measure` 的口径量一轮点按：
/// - 看板⇄会话：从看板开一个会话（主区换成会话页）、再点会话条的"进展"回来，走点击的同一条路（`openSession`、`selectPane`）。
/// - Cue 面板：点 Cue 栏头头像那一块开合（`CueTitle` 交出的同一个开关，`debugExposesCuePanel`），与 iOS 那两项同名。
extension InteractionBench {
    static func measureBoard(_ workspace: Workspace, sessions: [String], only: Set<String>?, step: (String, () -> Void) async -> Void) async {
        func wants(_ names: String...) -> Bool { only.map { !$0.isDisjoint(with: names) } ?? true }
        let settings = workspace.services.settings
        settings.railExpanded = true
        settings.cueOpen = true
        if wants("看板→会话", "会话→看板"), let session = sessions.first {
            workspace.selectPane(.progress)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("看板→会话") { workspace.openSession(SessionState.recordID(sessionID: session), sessionID: session) }
                await step("会话→看板") { workspace.selectPane(.progress) }
            }
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
