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

    /// 交给新会话：就在交给 Agent 的输入框上发出（用哪家、哪个模型在那里已经选好），进度、没开成的原因与再开确认都在它上面；认领到了收起它、进那个会话。
    /// 这件任务上一次开的请求还没收尾、这里还不知道时（`resumeHandOff` 没读到，或读的那一下出了错）不发：先接上它，由你看了结果再定。
    /// 此刻开不了（没有 Mac、一家 Agent 都不能用）也不发，原因写在输入框上。
    @discardableResult
    func launchHandOff(_ outbox: Outbox, opening: String?, plan: HandOffPlan?) -> Task<Void, Never>? {
        if sessionLaunching(outbox.launchKey).launch == nil {
            do {
                if let pending = try unresolvedLaunch(of: outbox) {
                    resume(outbox.launchKey, with: pending, opened: Self.entering(outbox))
                    return nil
                }
            } catch {
                fail(error)
                return nil
            }
        }
        let (project, planned): (UUID?, String?) =
            switch plan?.destination {
            case .launch(let project, let host): (project, host)
            default: (outbox.project, nil)
            }
        let start = SessionStart(project: project, card: outbox.card, name: plan?.name, host: planned)
        guard let place = start.place(among: launchPlaces), let host = place.host else { return nil }
        do {
            let agents = try services.store.snapshot { try $0.macAgents(on: host) }.value
            return submitSession(
                start, in: place, draft: handOffDraft.retelling(outbox.card, as: opening),
                choice: services.settings.launchChoice(on: agents, in: place.project.id), opened: Self.entering(outbox))
        } catch {
            fail(error)
            return nil
        }
    }

    /// 交给 Agent 的输入框浮起时：这件任务有一次开会话的请求还没收尾（关过输入框、在别的设备上发的）就接着它。
    func resumeHandOff(_ outbox: Outbox) {
        let key = outbox.launchKey, opened = Self.entering(outbox)
        guard sessionLaunching(key).launch == nil else { return resume(key, opened: opened) }
        do {
            if let pending = try unresolvedLaunch(of: outbox) { resume(key, with: pending, opened: opened) }
        } catch {
            fail(error)
        }
    }

    private func unresolvedLaunch(of outbox: Outbox) throws -> SessionLaunch? {
        guard let card = outbox.card else { return nil }
        return try services.store.snapshot { store -> SessionLaunch? in
            guard let request = try store.unresolvedLaunches(for: card).first, let token = request.launch?.token else { return nil }
            return SessionLaunch(request: request.id, token: token)
        }.value
    }

    /// 认领到新会话：输入框还是为这一次浮着的就收起它、进那个会话；中途关了的留在原处。
    private static func entering(_ outbox: Outbox) -> LaunchOpened {
        { workspace, claimed in
            guard workspace.outbox?.id == outbox.id else { return }
            workspace.outbox = nil
            workspace.openSession(claimed.id)
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
