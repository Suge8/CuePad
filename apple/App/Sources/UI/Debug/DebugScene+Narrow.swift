#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 配 `-CuePadDemo YES`：`-CuePadNarrowWaiting N` 再加入 N 个拍板，检查固定块内部滚动；`-CuePadNarrowPane projects|progress` 起在满屏侧栏；
    /// `-CuePadNarrowCycle YES`（配录屏）：就绪后走一圈开侧栏的进展、换到项目、换回进展、再换到项目（中途反向：上一下换段的滑动还没停就点回去）、回 Cue，
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
            if let pane = defaults.string(forKey: "CuePadNarrowPane").flatMap(NavigationPane.init(rawValue:)) {
                workspace.selectPane(pane)
            }
        }
        if defaults.bool(forKey: "CuePadNarrowCycle") { Task { await cycleNarrow(workspace) } }
        if defaults.bool(forKey: "CuePadQuotaCycle") { Task { await cycleQuota() } }
    }

    /// `-CuePadQuotaCycle YES`（配 progress 画面录屏）：就绪后点额度钮开浮窗、过一会儿走点浮窗外面那条路关（`ModalScrim` 调的同一个 `close`），来回几遍；
    /// 第三遍在长出的半途就关，看中途反向。
    private static func cycleQuota() async {
        let stays: [Double] = [1.5, 1.5, 0.12, 1.5]
        await Task.wait(for: .seconds(3))
        for stay in stays {
            toggleQuota()
            await Task.wait(for: .seconds(stay))
            modals?.modal?.close()
            await Task.wait(for: .seconds(1.2))
        }
    }

    private static func cycleNarrow(_ workspace: Workspace) async {
        // 每步之前停多久是录屏的节奏，不是在等别的事；0.1 秒那一步落在上一下换段的弹簧中途（`Motion.nudge` 0.25 秒）
        let steps: [(pause: Double, step: () -> Void)] = [
            (1.5, { workspace.selectPane(.progress) }),
            (1.5, { workspace.selectPane(.projects) }),
            (1.5, { workspace.selectPane(.progress) }),
            (0.1, { workspace.selectPane(.projects) }),
            (1.5, { workspace.select(.cue) }),
        ]
        for (pause, step) in steps {
            await Task.wait(for: .seconds(pause))
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: DebugHooks.preset.reducesMotion)) { step() }  // 同分段里点一下
        }
    }
}
#endif
