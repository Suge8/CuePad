#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 走的是侧栏那一排与侧栏钮调的同一些 Workspace 方法（不是手势）。
    static func prepareNarrow(_ workspace: Workspace) async {
        await running("窄屏验收") {
            let store = workspace.services.store
            let recorder = demoRecorder(store)
            let extra = args.layoutOpts.narrowWaiting
            for index in 0..<max(0, extra) {
                let id = "ask-\(index + 1)"
                _ = try await recorder.update(
                    sessionID: id, state: .waitingForUser, title: id, directory: "demo",
                    question: Question(promptID: nil, kind: .unknown("editor"), text: String(localized: "编辑提交说明", table: "Demo")),
                    agent: .codex)
            }
            if let pane = args.layoutOpts.narrowPane.flatMap(NavigationPane.init(rawValue:)) {
                workspace.selectPane(pane)
            }
        }
        if args.layoutOpts.narrowCycle { Task { await cycleNarrow(workspace) } }
        if args.layoutOpts.quotaCycle { Task { await cycleQuota() } }
    }

    /// 走点浮窗外面那条路关（`ModalScrim` 调的同一个 `close`），第三遍在长出的半途就关，看中途反向。
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
