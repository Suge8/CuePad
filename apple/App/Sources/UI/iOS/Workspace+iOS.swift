#if os(iOS)
import CueStore
import SwiftUI

extension Workspace {
    func showEditor(_ card: UUID) { push(.card(card)) }

    func openLibrary(_ file: LibraryFile) {
        if layout == .narrow, case .libraryFile? = path.last { path[path.count - 1] = .libraryFile(file) } else { push(.libraryFile(file)) }
    }

    func sessionRoute(_ id: UUID, sessionID: String?) -> Route? {
        let seed = try? services.store.snapshot { try SessionDigest.read(id, sessionID: sessionID, from: $0) }.value
        return .session(id, sessionID: sessionID ?? seed?.session?.sessionID, seed: seed)
    }

    func handOff(_ leaf: Card) {
        openTask = nil
        outbox = Outbox(content: Outgoing.text(of: leaf), card: leaf.id, project: leaf.projectID)
    }

    @discardableResult
    func launchHandOff(_ outbox: Outbox, opening: String?) -> Task<Void, Never>? {
        guard let card = outbox.card else { return nil }
        return handOff(card, fresh: true, draft: handOffDraft.retelling(card, as: opening))
    }

    /// 宽屏上搜索是这一排里的那一页，不一定在最左。
    var searching: Bool { (pageRoute ?? mainRoute) == .search }

    func openSearch() {
        searchFocusRequests += 1
        if !searching { push(.search) }
    }

    func closeSearch() {
        guard searching else { return }
        if layout == .wide { closeColumn(pageHost) } else { back() }
    }

    func showsAlert(about session: UUID) -> Bool { !shownSessions.contains { $0.id == session } }

    func keeps(_ notice: Notice) -> Bool {
        if notice.tone == .pick { return pickingDock }
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
