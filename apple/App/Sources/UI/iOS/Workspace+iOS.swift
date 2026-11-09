#if os(iOS)
import CueStore
import SwiftUI

extension Workspace {
    func willSelect(_ route: Route, from previous: Route) {}

    func showEditor(_ card: UUID) { push(.card(card)) }

    /// 技能与规则的文件页推在技能与规则页上；已在一份文件页上时换掉它、不叠一层（去重的几份之间切换，返回回到技能与规则页）。
    func openLibrary(_ file: LibraryFile) {
        if layout == .narrow, case .libraryFile? = path.last { path[path.count - 1] = .libraryFile(file) } else { push(.libraryFile(file)) }
    }

    /// 先读出这一页：推入的第一帧就是标题与最新的对话（`SessionRoute.seed`），只有记录 id 的入口顺带补上 Pi 的会话 id。
    /// 读不出来时照常推入，由页面报错。
    func sessionRoute(_ id: UUID, sessionID: String?) -> Route? {
        let seed = try? services.store.snapshot { try SessionDigest.read(id, sessionID: sessionID, from: $0) }.value
        return .session(id, sessionID: sessionID ?? seed?.session?.sessionID, seed: seed)
    }

    /// 发给 Agent：收起任务气泡，浮起发给 Agent 的输入框，正文带在里面（`HandOffInput`；Mac 直接按交到哪的决定发出，见 `Sending`）。
    func handOff(_ leaf: Card) {
        openTask = nil
        outbox = Outbox(content: Outgoing.text(of: leaf), card: leaf.id, project: leaf.projectID)
    }

    func prepareNewSession(_ draft: ComposerDraft, card: UUID?, opening: String?, plan: HandOffPlan?) {
        let claim = claimImports(draft)
        guard !claim.isEmpty else { return handOffToNewSession(draft.retelling(card, as: opening), card: card, plan: plan) }
        Task { handOffToNewSession(await claim.settled().retelling(card, as: opening), card: card, plan: plan) }
    }

    func claimSession(_ session: UUID) {
        newSession = nil
        openSession(session)
    }

    /// 发给 Agent 时选了新会话：收起发给 Agent 的输入框，换成新会话的，草稿带过去。
    /// 在哪开、由哪台 Mac 开、会话名按交到哪的决定（`plan`）；没有决定（读不出来）时用输入框自己的默认。
    func handOffToNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?) {
        let (project, host): (UUID?, String?) =
            switch plan?.destination {
            case .launch(let project, let host): (project, host)
            default: (outbox?.project, nil)
            }
        do {
            let launched = try services.store.snapshot { store -> SessionLaunch? in
                guard let card = card ?? draft.attachments.first?.card,
                      let request = try store.unresolvedLaunches(for: card).first,
                      let token = request.launch?.token else { return nil }
                return SessionLaunch(request: request.id, token: token)
            }.value
            outbox = nil
            newSession = SessionStart(project: project, launched: launched, draft: draft, card: card, name: plan?.name, host: host)
        } catch { fail(error) }
    }

    /// 搜索页推在当前页上并聚焦搜索框（已在搜索页时只聚焦），退出就是返回。
    func openSearch() {
        searchFocusRequests += 1
        if top != .search { push(.search) }
    }

    func closeSearch() {
        if top == .search { back() }
    }

    /// 项目进了回收站：窄屏移除它及后继页，宽屏回到项目书架。
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

    /// 会话的前台提示（等你确认、做完了）弹不弹：开着这个会话页时不弹（与系统通知同一条规则，见 `AlertCenter`）。
    func showsAlert(about session: UUID) -> Bool { !shownSessions.contains { $0.id == session } }

    /// 顶上那条提示还留不留：说的是某个会话的提示（等你确认、做完了），你进了那个会话就当场撤下
    /// （与不弹同一条规则 `showsAlert`），不在正看着的页面上停满 5 秒；别的提示照常留到时间。
    func keeps(_ notice: Notice) -> Bool {
        guard case .session(let route)? = notice.link else { return true }
        return showsAlert(about: route.id)
    }
}

extension Route {
    var isCard: Bool { if case .card = self { true } else { false } }
}

/// 卡片 ↔ 编辑纸页的缩放过渡共用的命名空间。
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
