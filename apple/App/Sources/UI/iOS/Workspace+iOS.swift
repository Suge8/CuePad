#if os(iOS)
import CueStore
import SwiftUI

extension Workspace {
    func willSelect(_ route: Route, from previous: Route) {}

    func showEditor(_ card: UUID) { push(.card(card)) }

    func openLibrary(_ file: LibraryFile) {
        if layout == .narrow, case .libraryFile? = path.last { path[path.count - 1] = .libraryFile(file) } else { push(.libraryFile(file)) }
    }

    /// 读不出来时照常推入，由页面报错。
    func sessionRoute(_ id: UUID, sessionID: String?) -> Route? {
        let seed = try? services.store.snapshot { try SessionDigest.read(id, sessionID: sessionID, from: $0) }.value
        return .session(id, sessionID: sessionID ?? seed?.session?.sessionID, seed: seed)
    }

    func handOff(_ leaf: Card) {
        openTask = nil
        outbox = Outbox(content: Outgoing.text(of: leaf), card: leaf.id, project: leaf.projectID)
    }

    /// 交给新会话：换成新会话的输入框并当场发出（用哪家、哪个模型在交给的那个输入框里已经选好）；进度、没开成的原因与再开确认都在新会话的输入框上。
    /// 这个任务上一次开的结果还没定时不发，留给你在输入框上看了再定。
    /// 交给的输入框当场收起：附件还在存时等它存完才换上新会话的输入框，这之间再按一次、换去交另一条任务，晚到的这一次都不会再动到。
    func startNewSession(_ draft: ComposerDraft, card: UUID?, opening: String?, plan: HandOffPlan?) {
        let project = outbox?.project
        outbox = nil
        let claim = claimImports(draft)
        guard !claim.isEmpty else { return launchNewSession(draft.retelling(card, as: opening), card: card, plan: plan, project: project) }
        Task { launchNewSession(await claim.settled().retelling(card, as: opening), card: card, plan: plan, project: project) }
    }

    private func launchNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?, project: UUID?) {
        guard showNewSession(draft, card: card, plan: plan, project: project),
              let start = newSession, start.launched == nil, let place = start.place(among: launchPlaces), let host = place.host else { return }
        do {
            let agents = try services.store.snapshot { try $0.macAgents(on: host) }.value
            submitSession(start, in: place, draft: draft, choice: services.settings.launchChoice(on: agents), opened: Self.entering(start))
        } catch { fail(error) }
    }

    func claimSession(_ session: UUID) {
        newSession = nil
        openSession(session)
    }

    func handOffToNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?) {
        if showNewSession(draft, card: card, plan: plan, project: outbox?.project) { outbox = nil }
    }

    /// `project`：去向不是开新会话时（任务绑着会话、另开一个）开在哪个项目。读不出上一次开的结果时不换输入框，返回 false。
    private func showNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?, project fallback: UUID?) -> Bool {
        let (project, host): (UUID?, String?) =
            switch plan?.destination {
            case .launch(let project, let host): (project, host)
            default: (fallback, nil)
            }
        do {
            let launched = try services.store.snapshot { store -> SessionLaunch? in
                guard let card = card ?? draft.attachments.first?.card,
                      let request = try store.unresolvedLaunches(for: card).first,
                      let token = request.launch?.token else { return nil }
                return SessionLaunch(request: request.id, token: token)
            }.value
            newSession = SessionStart(project: project, launched: launched, draft: draft, card: card, name: plan?.name, host: host)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func openSearch() {
        searchFocusRequests += 1
        if top != .search { push(.search) }
    }

    func closeSearch() {
        if top == .search { back() }
    }

    func pop(_ project: UUID?) {
        guard let project else { return }
        if services.settings.currentProject == project { services.settings.currentProject = nil }
        switch layout {
        case .narrow:
            if let index = path.firstIndex(of: .project(project)) { path = Array(path[..<index]) }
        case .wide:
            if mainRoute == .project(project) { select(.shelf) }
        }
    }

    /// 与系统通知同一条规则（`AlertCenter`）。
    func showsAlert(about session: UUID) -> Bool { !shownSessions.contains { $0.id == session } }

    /// 说的是某个会话的提示时，你进了那个会话就当场撤下，不在正看着的页面上停满 5 秒。
    func keeps(_ notice: Notice) -> Bool {
        guard case .session(let route)? = notice.link else { return true }
        return showsAlert(about: route.id)
    }
}

extension Route {
    var isCard: Bool { if case .card = self { true } else { false } }
}

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func zoomSource(_ id: UUID, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}
#endif
