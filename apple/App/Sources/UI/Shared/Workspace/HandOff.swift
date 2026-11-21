import CueStore
import Foundation

extension Workspace {
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
                await workspace.send(try await store.opening(of: plan.leaf, false), to: AgentTarget(session: session, host: host), card: task).value
                #endif
                return nil
            case .launch(let project, let host):
                let agents = try await store.macAgents(on: host)
                guard let choice = services.settings.launchChoice(on: agents, in: project), let agent = choice.agent else {
                    throw SendError.noAgent(here: host == workspace.localHost, agents.whyNone)
                }
                let prompt = if let claim { await claim.settled().stored } else { try await store.opening(of: plan.leaf, true) }
                let title = if let name = plan.name { name } else { try await store.project(project)?.shownName ?? "" }
                return try await services.launchSession(
                    in: project, prompt: prompt.nonEmpty, title: title, on: host, card: task, agent: agent,
                    model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
            }
        }
    }

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

    func launchUnsettled(_ task: UUID) -> Bool {
        switch sessionLaunching(.card(task)).phase(at: services.speech) {
        case .unconfirmed, .missing: true
        default: false
        }
    }

    func isLaunching(_ task: UUID, in agents: AgentLinks) -> Bool {
        agents.launching[task] != nil && !launchUnsettled(task)
    }

    private func adopt(_ task: UUID, _ launch: SessionLaunch) {
        resume(.card(task), with: launch, opened: Self.handedOff(task))
    }

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
