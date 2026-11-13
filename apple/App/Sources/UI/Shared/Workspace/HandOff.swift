import CueStore
import Foundation

extension Workspace {
    /// 把任务交给 Agent 只有这一条路（Mac 任务的"开始"、手机交给 Agent 的输入框发往新会话）。去处按 `CueStore.handOffPlan`：
    /// 绑着会话或有能接着的就交给它（`fresh` 另开；手机交给已有会话走回复框，只以 `fresh` 调到这里），否则在它定的那台 Mac 上开新会话，
    /// 用哪家、哪个模型按上次选的（`AppSettings.launchChoice`）。`draft` 为 nil 时开场白是任务正文。
    /// 这件任务上一次开的请求还没收尾、这里还不知道时不发：先接上它（`resumeHandOff`），由你看了结果再定。
    /// 没开成的原因留在 `sessionLaunching(.card(task))` 上。返回写请求的那个任务（测试等它）；接上旧请求、在等着或要先确认时为 nil。
    @discardableResult
    func handOff(_ task: UUID, fresh: Bool, draft: ComposerDraft? = nil, opened: LaunchOpened? = nil) -> Task<Void, Never>? {
        let key = SessionLaunching.Key.card(task)
        if sessionLaunching(key).launch == nil {
            do {
                if try resumeHandOff(task, opened: opened) { return nil }
            } catch {
                fail(error)
                return nil
            }
        }
        let claim = draft.map(claimImports)
        return launch(sessionLaunching(key), opened: opened) { [services] workspace, intent in
            let store = services.store
            let plan = try await store.handOffPlan(task, host: workspace.localHost, fresh: fresh)
            switch plan.destination {
            case .session(let session, _, let host):
                #if os(macOS)
                workspace.send(try await store.opening(of: plan.leaf, false), to: AgentTarget(session: session, host: host), card: task)
                #endif
                return nil
            case .launch(let project, let host):
                let agents = try await store.macAgents(on: host)
                guard let choice = services.settings.launchChoice(on: agents, in: project), let agent = choice.agent else {
                    throw SendError.noAgent(here: host == workspace.localHost, agents.whyNone)
                }
                let prompt = if let claim { await claim.settled().stored } else { try await store.opening(of: plan.leaf, true) }
                // 会话名由任务定（`CueStore.requestLaunch`）；请求上显示的目标名同新会话的其他入口：任务没有标题时写项目名
                let title = if let name = plan.name { name } else { try await store.project(project)?.shownName ?? "" }
                return try await services.launchSession(
                    in: project, prompt: prompt.nonEmpty, title: title, on: host, card: task, agent: agent,
                    model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
            }
        }
    }

    /// 接着看这件任务开会话的进度（交给 Agent 的输入框浮起、Mac 的任务气泡出现时）：这里已知的那一次照样等，认领到时按这一次的 `opened` 收尾；
    /// 还不知道的（重启过、关过输入框、在别的设备上发的）从库里接上没收尾的那一次。有一次在等为 true。
    @discardableResult
    func resumeHandOff(_ task: UUID, opened: LaunchOpened?) throws -> Bool {
        let key = SessionLaunching.Key.card(task)
        if sessionLaunching(key).launch != nil {
            resume(key, opened: opened)
            return true
        }
        let pending = try services.store.snapshot { store -> SessionLaunch? in
            guard let request = try store.unresolvedLaunches(for: task).first, let token = request.launch?.token else { return nil }
            return SessionLaunch(request: request.id, token: token)
        }.value
        guard let pending else { return false }
        resume(key, with: pending, opened: opened)
        return true
    }
}
