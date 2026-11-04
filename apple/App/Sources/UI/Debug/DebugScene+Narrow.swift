#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 配 `-CuePadDemo YES`：`-CuePadNarrowWaiting N` 再加入 N 个拍板，检查固定块内部滚动；`-CuePadNarrowPane projects|progress` 起在满屏侧栏，
    /// `-CuePadProgressPane board|sessions` 定进展停在哪一段；`-CuePadNarrowCycle YES`（配录屏）：就绪后走一圈开侧栏的进展、换到项目、换回进展、换会话段、回 Cue，
    /// 每步隔 1.5 秒，走的是侧栏那一排与侧栏钮调的同一些 Workspace 方法（不是手势）。
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
            // PROTOTYPE：`-CuePadNavEarlier YES` 起来就推入"更早"那一页（方案 one）
            if defaults.bool(forKey: "CuePadNavEarlier") { NavProtoBus.shared.earlier = true }
        }
        if defaults.bool(forKey: "CuePadNarrowCycle") { Task { await cycleNarrow(workspace) } }
    }

    private static func cycleNarrow(_ workspace: Workspace) async {
        let steps: [() -> Void] = [
            { workspace.selectPane(.progress) },
            { workspace.selectPane(.projects) },
            { workspace.selectPane(.progress) },
            { workspace.progressPane = workspace.progressPane == .board ? .sessions : .board },
            { workspace.select(.cue) },
        ]
        // 两步之间停多久是录屏的节奏，不是在等别的事
        for step in steps {
            await Task.wait(for: .seconds(1.5))
            withAnimation(Motion.fading(Motion.nudge, reduceMotion: false)) { step() }  // 同分段里点一下
        }
    }
}
#endif
