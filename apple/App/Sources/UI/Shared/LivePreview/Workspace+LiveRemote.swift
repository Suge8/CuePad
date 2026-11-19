#if os(iOS)
import CueStore
import Foundation

/// 手机、iPad 上的活预览：看的是会话所在那台 Mac 上的页面（`LiveRemote` 问来），经局域网隧道连过去（`LiveLink`）。
/// 宽屏开在右半（同 Mac），窄屏铺满一页（`LivePhoneCover`）。隧道只在看得见时开；预览（网页与登录状态）留到离开会话页（`keepLivePreviews`）。
extension Workspace {
    /// Mac 答来的这个会话可看的页面，点开时开的在前。只认开合预览的那一个会话（`liveRoute`）：别的会话没在问。
    func livePages(_ session: UUID) -> [URL] {
        guard let route = liveRoute, route.id == session else { return [] }
        return route.sessionID.flatMap { services.liveRemote.answers[$0]?.pages } ?? []
    }

    func showsLivePreview(_ session: UUID) -> Bool {
        switch layout {
        case .wide: beside == .preview && self.session(in: .main)?.id == session
        case .narrow: liveCover == session && liveRoute?.id == session
        }
    }

    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

    /// 开合活预览的那一个会话：宽屏是主区的，窄屏是导航最上面的。
    private var liveRoute: SessionRoute? {
        switch navigation {
        case .wide: session(in: .main)
        case .narrow(let state): if case .session(let route)? = state.path.last { route } else { nil }
        }
    }

    func toggleLivePreview() {
        guard let route = liveRoute else { return }
        let opening = !showsLivePreview(route.id)
        if opening {
            guard let first = livePages(route.id).first else { return }
            let preview = livePreviews[route.id] ?? LivePreview()
            preview.sessionID = route.sessionID
            if preview.address == nil { preview.retarget(.init(url: first, source: .found)) }
            livePreviews[route.id] = preview
        }
        switch navigation {
        case .wide(var state):
            state.beside = opening ? .preview : nil
            navigation = .wide(state)
        case .narrow:
            liveCover = opening ? route.id : nil
        }
    }

    /// 预览看得见的这段时间连着 Mac（`LivePreviewPane` 的 task）：收起（滑完、盖着的那一页落下）、进后台就断开，预览留着。
    func connectLive(_ preview: LivePreview) async {
        guard let sessionID = preview.sessionID, let host = services.liveRemote.host(sessionID) else { return }
        do {
            let link = try LiveLink()
            preview.link = link
            await link.run(preview, sessionID: sessionID, host: host, remote: services.liveRemote) { [weak self] in self?.services.liveSignaling?.liveTunnelKey }
            if preview.link === link { preview.link = nil }
        } catch {
            fail(error)
        }
    }

    /// 会话页还开着（窄屏在导航栈里，宽屏在主区或并排）就留着它的预览，离开了才放掉。导航一变就调（`navigation`）。
    func keepLivePreviews() {
        let open: Set<UUID> = switch navigation {
        case .wide: Set([session(in: .main), session(in: .beside)].compactMap { $0?.id })
        case .narrow(let state): Set(state.path.compactMap { if case .session(let route) = $0 { route.id } else { nil } })
        }
        let gone = livePreviews.filter { !open.contains($0.key) }.values
        guard !gone.isEmpty else { return }
        // 弹着的对话框先答掉：WebKit 等着的回调没调就放掉网页视图会抛异常
        for preview in gone { for ask in preview.asks { preview.answer(ask.id, nil) } }
        livePreviews = livePreviews.filter { open.contains($0.key) }
    }

    /// 点一个元素挂进回复框：宽屏回复框就在左边；手机上先把预览收回，回复框接过焦点。
    func pickElement() {
        guard let route = liveRoute, let preview = livePreviews[route.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: route.id)
            if layout == .narrow { liveCover = nil }
            replyFocus = route.id
        }
    }
}
#endif
