import CueStore
import Foundation

extension Workspace {
    /// 把任务交给 Agent 只有这一条路（Mac 任务的"开始"、手机交给 Agent 的输入框发往新会话）。去处按 `CueStore.handOffPlan`：
    /// 绑着会话或有能接着的就交给它（`fresh` 另开；手机交给已有会话走回复框，只以 `fresh` 调到这里），否则在它定的那台 Mac 上开新会话，
    /// 用哪家、哪个模型按上次选的（`AppSettings.launchChoice`）。`draft` 为 nil 时开场白是任务正文。
    /// 这件任务上一次开的请求还没收尾、这里还没接上时（`followUnresolvedLaunches` 还没读到）不发：先接上它，由你看了结果再定。
    /// 没开成的原因留在 `sessionLaunching(.card(task))` 上。返回写请求的那个任务（测试等它）；接上旧请求、在等着或要先确认时为 nil。
    @discardableResult
    func handOff(_ task: UUID, fresh: Bool, draft: ComposerDraft? = nil) -> Task<Void, Never>? {
        let key = SessionLaunching.Key.card(task)
        if sessionLaunching(key).launch == nil {
            do {
                if let pending = try services.store.snapshot({ try SessionLaunch.unresolved(of: task, in: $0) }).value {
                    adopt(task, pending)
                    return nil
                }
            } catch {
                fail(error)
                return nil
            }
        }
        let claim = draft.map(claimImports)
        return launch(sessionLaunching(key), opened: Self.handedOff(task)) { [services] workspace, intent in
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

    /// 库里每件任务没收尾的那次开会话都由这里接上：Mac 启动后、手机窗口建起来后，以及别的设备新发的。
    /// 任务气泡、步骤行、交给 Agent 的输入框只读 `sessionLaunching`，不各自去接。
    func followUnresolvedLaunches() async {
        do {
            for try await pending in services.store.observe({ try $0.latestUnresolvedLaunches().compactMapValues(SessionLaunch.init) }) {
                for (task, launch) in pending where sessionLaunching(.card(task)).launch == nil { adopt(task, launch) }
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 这件任务在开会话，可这里接上的那一次说不出结果（未确认、查不到）：可能已开过，不再显示"正在开"，"开始"换成"重试"、再开先问。
    func launchUnsettled(_ task: UUID) -> Bool {
        switch sessionLaunching(.card(task)).phase(at: services.speech) {
        case .unconfirmed, .missing: true
        default: false
        }
    }

    /// 在开会话、还没到说不出结果的地步：行上画"正在开"的圈，不给"开始"。
    func isLaunching(_ task: UUID, in agents: AgentLinks) -> Bool {
        agents.launching[task] != nil && !launchUnsettled(task)
    }

    private func adopt(_ task: UUID, _ launch: SessionLaunch) {
        resume(.card(task), with: launch, opened: Self.handedOff(task))
    }

    /// 认领到新会话时：手机上这件任务交给 Agent 的输入框还浮着就收起它、进那个会话，关了的留在原处；按任务认而不按哪一次浮起
    /// （请求还没写进库时关了又开，认领到时照样该收）。Mac 不动，任务那一行自己换成会话。
    private static func handedOff(_ task: UUID) -> LaunchOpened? {
        #if os(macOS)
        nil
        #else
        { workspace, claimed in
            guard workspace.outbox?.card == task else { return }
            workspace.outbox = nil
            workspace.openSession(claimed.id)
        }
        #endif
    }
}

nonisolated extension SessionLaunch {
    static func unresolved(of task: UUID, in store: isolated CueStore) throws -> SessionLaunch? {
        try store.unresolvedLaunches(for: task).first.flatMap(SessionLaunch.init)
    }

    init?(_ request: DeliveryRequest) {
        guard let token = request.launch?.token else { return nil }
        self.init(request: request.id, token: token)
    }
}
