#if os(iOS) && DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// `-CuePadNarrow YES` 配现有 Demo：给演示 Mac 与会话补同一次启动的运行证明，不改变原型的数据口径。
    /// `-CuePadNarrowWaiting N` 再加入 N 个拍板，检查固定块内部滚动；`-CuePadNarrowPane projects|progress` 起在满屏侧栏。
    static func prepareNarrow(_ workspace: Workspace) async {
        guard defaults.bool(forKey: "CuePadNarrow") else { return }
        await running("窄屏验收") {
            let store = workspace.services.store
            let host = "demo-mac", boot = "narrow-demo-boot"
            try await store.recordMacPresence(host: host, bootID: boot) { true }
            let recorder = PiStateRecorder(store: store, hostID: host, bootID: boot)
            let sessions = try await store.piSessionPage(.live).items.map(\.state).filter { $0.hostID == host }
            for session in sessions {
                guard let state = session.state.known else { continue }
                _ = try await recorder.update(
                    sessionID: session.sessionID, state: state, detail: session.detail, failure: session.failure?.known,
                    title: session.title, directory: session.folder, projectID: session.projectID, question: session.question,
                    times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), subagents: session.subagents,
                    agent: session.agent.known ?? .pi)
            }
            let extra = defaults.integer(forKey: "CuePadNarrowWaiting")
            for index in 0..<max(0, extra) {
                let id = "ask-\(index + 1)"
                _ = try await recorder.update(
                    sessionID: id, state: .waitingForUser, title: id, directory: "demo",
                    question: PiQuestion(promptID: nil, kind: .unknown("editor"), text: String(localized: "编辑提交说明", table: "Demo")),
                    agent: .codex)
            }
            if let state = try await store.cueState() {
                try await store.setCueState(state.state.known ?? .settled, hostID: host, bootID: boot)
            }
            if let pane = defaults.string(forKey: "CuePadNarrowPane").flatMap(NavigationPane.init(rawValue:)) {
                workspace.selectPane(pane)
            }
        }
    }
}
#endif
