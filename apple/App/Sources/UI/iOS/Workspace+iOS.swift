#if os(iOS)
import CueStore
import SwiftUI

/// iOS 怎么摆去处（`Workspace+Navigation`）：宽屏是分栏（`.split`），窄屏是底部那一排（`.dock`，`IOSRoot` 按尺寸类换）；
/// 卡片纸页与会话页推在当前页上。还有只在手机与 iPad 上的浮层：发给 Agent、新会话、搜索页。
extension Workspace.Layout {
    static let native = Self.split
}

extension Workspace {
    /// 打开 App 先到 `Route.first`；iPad 的窗口恢复时再选回上次的项目（`restore`）。
    static func openingRoute(_ services: AppServices) -> Route { .first }

    /// 换去处没有顺带的事。
    func willSelect(_ route: Route, root next: Route) {}

    /// 点底部那一排的一格（同系统标签栏）：换到那个 tab，它的栈原样留着；点的就是所在的 tab 时回到它的根。
    func tap(_ tab: Route) {
        if tab == root { path = [] } else { root = tab }
    }

    /// UIKit 的回调里换 tab（点系统标签栏的格子、横滑松手、读屏的三指滑）：排到主线程的下一轮再 `tap`。
    /// 在 UIKit 派发触摸的那一下里改 `root`，SwiftUI 有时在 willSet 里当场把读它的视图重算一遍（读到的还是旧值），又漏掉紧接着真正的改动：
    /// 标签栏选了新的格子、页却一直停在旧 tab 上（iOS 27 实测，调用栈是 `ObservationRegistrar.willSet` → `GraphHost.flushTransactions`）。
    func tapSoon(_ tab: Route) { Task { self.tap(tab) } }

    /// 推回 Cue 页上刚返回离开的那一页（左滑前进，`LeaveShot`）。会话页按此刻重读首帧（同 `openSession`）：离开后对话可能又长了。
    func goForward(to route: Route) {
        guard case .session(let session) = route else { return push(route) }
        push(sessionRoute(session.id, sessionID: session.sessionID) ?? route)
    }

    /// 灵感的纸页推在当前页上。
    func showEditor(_ card: UUID) { push(.card(card)) }

    /// 技能与规则的文件页推在技能与规则页上；已在一份文件页上时换掉它、不叠一层（去重的几份之间切换，返回回到技能与规则页）。
    func openLibrary(_ file: LibraryFile) {
        if case .libraryFile? = path.last { path[path.count - 1] = .libraryFile(file) } else { push(.libraryFile(file)) }
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

    /// 发给 Agent 时选了新会话：收起发给 Agent 的输入框，换成新会话的，草稿带过去。
    /// 在哪开、由哪台 Mac 开、会话名按交到哪的决定（`plan`）；没有决定（读不出来）时用输入框自己的默认。
    func handOffToNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?) {
        let (project, host): (UUID?, String?) =
            switch plan?.destination {
            case .launch(let project, let host): (project, host)
            default: (outbox?.project, nil)
            }
        outbox = nil
        newSession = NewSessionInput.Start(project: project, draft: draft, card: card, name: plan?.name, host: host)
    }

    /// 宽屏：恢复窗口时选回上次侧栏选中的项目；它已不在项目目录里（进了回收站、被删）时留在打开 App 的那一页。
    /// 分栏只在目录读到后才建出（`CatalogGate`），这里当场判定，不先推一张空的项目页再退回。
    /// 已经选着它时不动：分栏随窗口宽窄重建（宽 → 窄 → 宽）时，项目页上推入的页留着。
    func restore(project: UUID?) {
        guard let project, root != .project(project), catalog?.project(project) != nil else { return }
        select(.project(project))
    }

    /// 搜索页推在当前页上并聚焦搜索框（已在搜索页时只聚焦），退出就是返回。
    func openSearch() {
        searchFocusRequests += 1
        if top != .search { push(.search) }
    }

    func closeSearch() {
        if top == .search { path.removeLast() }
    }

    /// 项目进了回收站：从各个栈里移除它的页面（连同推在它上面的）。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        for (tab, stack) in stacks {
            if let index = stack.firstIndex(of: gone) { self[stack: tab] = Array(stack[..<index]) }
        }
        if root == gone { select(.shelf) }
    }

    /// 会话的前台提示（等你确认、做完了）弹不弹：开着这个会话页时不弹（与系统通知同一条规则，见 `AlertCenter`）。
    func showsAlert(about session: UUID) -> Bool { shownSession?.id != session }

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
