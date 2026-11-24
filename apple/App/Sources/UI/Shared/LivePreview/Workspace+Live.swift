import CueStore
import Foundation

extension Workspace {
    /// 没点名时说的是开着预览的那个会话，没有就是这一排最左的会话；窄屏是路上最顶上的会话页。
    var liveSession: SessionRoute? {
        switch navigation {
        case .wide(let state): state.sessions.first { $0.id == state.preview } ?? state.sessions.first
        case .narrow(let state): if case .session(let route)? = state.path.last { route } else { nil }
        }
    }

    func showsLivePreview(_ session: UUID) -> Bool {
        switch navigation {
        case .wide(let state): state.preview == session
        case .narrow: liveCover == session && liveSession?.id == session
        }
    }

    func livePages(_ session: UUID) -> [URL] { livePreviews.pages(session) }

    func hasLivePage(_ session: UUID) -> Bool { !livePages(session).isEmpty }

    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

    func toggleLivePreview(of session: SessionRoute? = nil) {
        guard let route = session ?? liveSession else { return }
        let opening = !showsLivePreview(route.id)
        if opening, !livePreviews.show(route.id, sessionID: route.sessionID) { return }
        switch navigation {
        case .wide(var state):
            state.togglePreview(of: route.id, room: wideRoom)
            presentWide(state)
        case .narrow:
            liveCover = opening ? route.id : nil
        }
    }

    /// 地址栏、空的地址输入里填的：认不出是地址时不动。
    @discardableResult func typeLive(_ text: String, for session: UUID) -> Bool {
        guard let url = LiveAddress.url(from: text), let sessionID = shownSessions.first(where: { $0.id == session })?.sessionID else { return false }
        livePreviews.type(url, for: session, sessionID: sessionID)
        return true
    }

    func pickElement() {
        guard let route = liveSession, let preview = livePreviews[route.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: route.id)
            if layout == .narrow { liveCover = nil } else { endLiveFill() }
            replyFocus = route.id
        }
    }
}
