#if os(macOS)
import CueBridge
import CueStore
import CueText
import SwiftUI

extension Workspace {
    /// 开新会话时按任务存（`SessionLaunching`）：没开成的原因留在任务那一行，可能已开过时先确认。返回写请求的那个任务（测试等它）；在等着或要先确认时为 nil。
    @discardableResult
    func handOff(_ leaf: Card) -> Task<Void, Never>? {
        start(leaf.id, fresh: false)
    }

    func startFresh(_ leaf: Card) {
        start(leaf.id, fresh: true)
    }

    @discardableResult
    private func start(_ leaf: UUID, fresh: Bool) -> Task<Void, Never>? {
        launch(sessionLaunching(.card(leaf))) { [services] workspace, intent in
            let store = services.store
            let plan = try await store.handOffPlan(leaf, host: services.hostID, fresh: fresh)
            let text = try await store.opening(of: leaf, plan.opensSession)
            switch plan.destination {
            case .session(let session, _, let host):
                workspace.send(text, to: AgentTarget(session: session, host: host), card: leaf)
                return nil
            case .launch(let project, let host):
                // 会话名由任务定（`CueStore.requestLaunch`）；请求上显示的目标名同新会话的其他入口：任务没有标题时写项目名
                let projectName = try await store.project(project)?.shownName ?? ""
                let title = plan.name ?? projectName
                // 用哪家、哪个模型同新会话的输入框：上次选的（任务气泡的"开始"旁边那一排改的也是它）
                let agents = try await store.macAgents(on: host)
                guard let choice = services.settings.launchChoice(on: agents), let agent = choice.agent else {
                    throw SendError.noAgent(here: host == services.hostID, agents.whyNone)
                }
                return try await services.launchSession(
                    in: project, prompt: text.nonEmpty, title: title, on: host, card: leaf, agent: agent,
                    model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
            }
        }
    }

    /// 经 `speak` 写出就提示，不等送达。返回写库与上传的那个任务（测试等它）。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) -> Task<Void, Never> {
        let (listener, handed) = sendState.destination(to: target, card: card)
        return speak(stored, to: listener, saying: handed)
    }
}

extension Workspace {
    func followSessionPlacement() async {
        for await _ in Observations({ self.sessionPlacement }) {
            do { try await sendState.refreshSessionProjects() } catch { fail(error) }
        }
    }

    private struct SessionPlacement: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    private var sessionPlacement: SessionPlacement {
        SessionPlacement(sessions: services.bridge.slots.map { "\($0.id) \($0.cwd.path)" }, directories: catalog?.directories)
    }
}
#endif
