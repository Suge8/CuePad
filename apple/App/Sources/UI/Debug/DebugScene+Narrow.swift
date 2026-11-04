#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 配 `-CuePadDemo YES`：`-CuePadNarrowWaiting N` 再加入 N 个拍板，检查固定块内部滚动；`-CuePadNarrowPane projects|progress` 起在满屏侧栏，
    /// `-CuePadProgressPane board|sessions` 定进展停在哪一段。
    static func prepareNarrow(_ workspace: Workspace) async {
        await running("窄屏验收") {
            let store = workspace.services.store
            let recorder = demoRecorder(store)
            let extra = defaults.integer(forKey: "CuePadNarrowWaiting")
            for index in 0..<max(0, extra) {
                let id = "ask-\(index + 1)"
                _ = try await recorder.update(
                    sessionID: id, state: .waitingForUser, title: id, directory: "demo",
                    question: PiQuestion(promptID: nil, kind: .unknown("editor"), text: String(localized: "编辑提交说明", table: "Demo")),
                    agent: .codex)
            }
            if let pane = defaults.string(forKey: "CuePadProgressPane").flatMap(ProgressPane.init(rawValue:)) { workspace.progressPane = pane }
            if let pane = defaults.string(forKey: "CuePadNarrowPane").flatMap(NavigationPane.init(rawValue:)) {
                workspace.selectPane(pane)
            }
        }
    }
}
#endif
