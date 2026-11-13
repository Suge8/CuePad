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
    @discardableResult
    func launchHandOff(_ outbox: Outbox, opening: String?) -> Task<Void, Never>? {
        guard let card = outbox.card else { return nil }
        return handOff(card, fresh: true, draft: handOffDraft.retelling(card, as: opening))
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
