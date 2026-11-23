#if os(iOS)
import CueStore
import Foundation
import UIKit

extension Workspace {
    func livePages(_ session: UUID) -> [URL] { liveAnswer(session)?.pages ?? [] }

    private func liveAnswer(_ session: UUID) -> LiveRemote.Pages? {
        guard let route = liveRoute, route.id == session else { return nil }
        return route.sessionID.flatMap { services.liveRemote.answers[$0] }
    }

    func showsLivePreview(_ session: UUID) -> Bool {
        switch layout {
        case .wide: panes.contains(.preview(session))
        case .narrow: liveCover == session && liveRoute?.id == session
        }
    }

    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

    private var liveRoute: SessionRoute? {
        switch navigation {
        case .wide(let state): state.sessions.first { $0.id == state.preview } ?? state.sessions.first
        case .narrow(let state): if case .session(let route)? = state.path.last { route } else { nil }
        }
    }

    var liveSession: SessionRoute? { liveRoute }

    func toggleLivePreview(of session: SessionRoute? = nil) {
        guard let route = liveRoute, session == nil || session == route else { return }
        let opening = !showsLivePreview(route.id)
        if opening {
            guard let answer = liveAnswer(route.id), !answer.pages.isEmpty else { return }
            let preview = livePreviews[route.id] ?? LivePreview()
            preview.sessionID = route.sessionID
            preview.host = route.sessionID.flatMap(services.liveRemote.host)
            preview.follow(answer, showing: false)
            livePreviews[route.id] = preview
        }
        switch navigation {
        case .wide(var state):
            if opening != (state.preview == route.id) { state.togglePreview(of: route.id, room: wideRoom) }
            navigation = .wide(state)
        case .narrow:
            liveCover = opening ? route.id : nil
        }
    }

    func connectLive(_ preview: LivePreview) async {
        guard let sessionID = preview.sessionID, let host = preview.host else { return }
        do {
            let link = try LiveLink()
            preview.link = link
            await link.run(preview, sessionID: sessionID, host: host, remote: services.liveRemote) { [weak self] in self?.services.liveSignaling?.liveTunnelKey }
            if preview.link === link { preview.link = nil }
        } catch {
            fail(error)
        }
    }

    func keepLivePreviews() {
        let open: Set<UUID> = switch navigation {
        case .wide(let state): Set(state.sessions.map(\.id))
        case .narrow(let state): Set(state.path.compactMap { if case .session(let route) = $0 { route.id } else { nil } })
        }
        let gone = livePreviews.filter { !open.contains($0.key) }.values
        guard !gone.isEmpty else { return }
        // 弹着的对话框先答掉：WebKit 等着的回调没调就放掉网页视图会抛异常
        for preview in gone { for ask in preview.asks { preview.answer(ask.id, nil) } }
        livePreviews = livePreviews.filter { open.contains($0.key) }
    }

    func viewOnMac(_ preview: LivePreview) async {
        guard let sessionID = preview.sessionID, let host = preview.host else { return }
        await operate(on: host, viewing: sessionID)
    }

    func followReturns() async {
        let activations = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
        await returnFromMac()
        for await _ in activations { await returnFromMac() }
    }

    func returnFromMac() async { await services.liveRemote.comeBack() }

    func pickElement() {
        guard let route = liveRoute, let preview = livePreviews[route.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: route.id)
            if layout == .narrow { liveCover = nil } else { endLiveFill() }
            replyFocus = route.id
        }
    }
}
#endif
