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

    /// 换去处没有顺带的事：底部那一排的"⋯"与输入框焦点跟着去处走，在窄屏的容器里（`DockRoot`）。
    func willSelect(_ route: Route, root next: Route) {}

    /// 灵感的纸页推在当前页上。
    func showEditor(_ card: UUID) { push(.card(card)) }

    /// 技能与说明里的一样（说明的编辑页、比一比）推在技能与说明页上；比一比合成之后打开的说明换掉比一比（返回回到技能与说明页）。
    func openLibrary(_ item: LibraryItem) {
        if case .instruction = item, case .libraryItem(.compare)? = path.last {
            path[path.count - 1] = .libraryItem(item)
        } else {
            push(.libraryItem(item))
        }
    }

    /// 一份说明在手机上的编辑：改着没发的留在这里，离开说明页再回来接着改、接着发——不点纸飞机就不发，也不丢（App 退出才没了）。
    /// 按 `host` 那台 Mac 分开：Cue 换到另一台后看的是那台的说明，在这台没发的字不拿去对着那台。
    /// 再打开时先对上快照里此刻的样子（没改过就跟上，改着的就说 Mac 上改过了）。
    func instructionDraft(_ instruction: LibraryInstruction, on host: String) -> InstructionDraft {
        let key = InstructionDraftKey(host: host, kind: instruction.kind)
        if let draft = instructionDrafts[key] {
            draft.follow(instruction.text)
            return draft
        }
        let draft = InstructionDraft(instruction, workspace: self)
        instructionDrafts[key] = draft
        return draft
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

    /// 项目进了回收站：从路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        if let index = path.firstIndex(of: gone) { path.removeSubrange(index...) }
        if forward == gone { forward = nil }
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

/// 手机上改着的一份说明是哪台 Mac 的哪一份（`Workspace.instructionDrafts`）。
struct InstructionDraftKey: Hashable {
    let host: String
    let kind: LibraryInstruction.Kind
}
#endif
