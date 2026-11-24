#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
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
        if let dock = args.inspirationOpts.dock { await running("边聊边看") { try await presetDock(dock, workspace) } }
        if args.layoutOpts.narrowCycle { Task { await cycleNarrow(workspace) } }
        if args.layoutOpts.quotaCycle { Task { await cycleQuota() } }
    }

    private static func presetDock(_ dock: String, _ workspace: Workspace) async throws {
        guard let card = try await card(in: Project.defaultID, store: workspace.services.store) else { return }
        if dock == "pick" { return workspace.pickDock(card) }
        guard case .session(let session)? = workspace.path.last else { return }
        workspace.setDock(IdeaDock(card: card, session: session.id, open: dock == "open"))
    }

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
        let steps: [(pause: Double, step: () -> Void)] = [
            (1.5, { workspace.selectPane(.progress) }),
            (1.5, { workspace.selectPane(.projects) }),
            (1.5, { workspace.selectPane(.progress) }),
            (0.1, { workspace.selectPane(.projects) }),
            (1.5, { workspace.select(.cue) }),
        ]
        for (pause, step) in steps {
            await Task.wait(for: .seconds(pause))
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: DebugHooks.args.layoutOpts.reduceMotion)) { step() }
        }
    }
}
#endif
