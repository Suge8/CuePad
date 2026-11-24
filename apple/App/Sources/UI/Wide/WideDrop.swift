import CueStore
import SwiftUI
import UniformTypeIdentifiers

/// 拖一块的胶囊时带的东西：把这一排里的一块挪个位置。页不用说是哪一页（一排至多一页），别的窗口不接。
nonisolated struct DraggedColumn: Codable, Sendable {
    enum Piece: Codable {
        case page
        case session(recordID: UUID, sessionID: String?)
        case card(UUID)
    }

    let windowID: UUID
    let piece: Piece
    static let type = UTType(exportedAs: "\(AppIdentity.id).column", conformingTo: .data)

    @MainActor init?(windowID: UUID, _ pane: WideNavigation.Pane) {
        switch pane {
        case .page: piece = .page
        case .session(let route): piece = .session(recordID: route.id, sessionID: route.sessionID)
        case .card(let id): piece = .card(id)
        case .preview: return nil
        }
        self.windowID = windowID
    }
}

extension EnvironmentValues {
    @Entry var wideWindowID: UUID?
}

enum WideDropZone: Equatable {
    case before, replace, after
}

struct WideDropTarget: Equatable {
    let column: Workspace.Column
    let zone: WideDropZone
    let pane: WideNavigation.Pane
    let next: WideNavigation
}

/// 拖着时主区认的拖的是哪一块，由拖起的那一头报（`reportsWideDrag`、胶囊的 `PaneGrip`）。别的窗口、别的 App 拖来的没人报，按类型猜；
/// `refused` 是主区不接的（不带会话的任务卡）。
enum WideDrag: Equatable {
    case unknown, refused
    case pane(WideNavigation.Pane)
}

/// 宽屏主区接的拖放（Mac 的 `WideColumnView`、iPad 的 `WideColumnController`）：每一块的胶囊（`PaneTitle`）、会话条的行、带会话的看板卡、灵感卡。
/// 从页里拖起的卡（带 `.cuepadCard`）先问指针下页里自己的落点（看板换列、任务行排序、灵感拖到任务上），页接了主区就不接；页不接才按下面的规则。
/// 落在一块的左右四分之一插在它旁边，正中换掉它；放满了只能换。独占的页（进展）只能换掉，从页里拖起的卡在它上面主区不接。
/// 已在这一排的是挪位置：落在别的块上哪里都有结果，插过去位置没变（本来就挨着）就与那一块对调。
/// 从页里拖起的卡不换掉页、灵感卡不换掉别的块：正中也放到那一块右边，放满了才换。
/// 拖着时主区按拖起的那一头报的认是哪一块（`Workspace.dragging`），没人报的按类型猜：带会话的当会话，只带卡的当灵感。
enum WideDrop {
    static let types: [UTType] = [DraggedColumn.type, .cuepadSession, .cuepadCard]

    static func target(_ types: Set<UTType>, at fraction: CGFloat, in column: Workspace.Column, workspace: Workspace) -> WideDropTarget? {
        guard case .wide(let state) = workspace.navigation, let over = workspace.pane(in: column) else { return nil }
        let session = types.contains(DraggedColumn.type) || types.contains(.cuepadSession)
        guard session || types.contains(.cuepadCard) else { return nil }
        let pane: WideNavigation.Pane
        switch workspace.dragging {
        case .pane(let known): pane = known
        case .refused: return nil
        case .unknown: pane = session ? .session(standIn) : .card(standIn.id)
        }
        guard over != pane else { return nil }
        let fresh = !state.panes.contains(pane)
        let full = fresh && workspace.wideShown >= workspace.wideRoom
        let card = types.contains(.cuepadCard)
        if card, over.standsAlone { return nil }
        var zone: WideDropZone = over.standsAlone || full ? .replace : fraction < 0.25 ? .before : fraction > 0.75 ? .after : .replace
        if zone == .replace, card, fresh, !full, pane.card != nil || over.page != nil { zone = .after }
        func landing(_ zone: WideDropZone) -> WideDropTarget? {
            guard let next = state.dropping(pane, at: column.index + (zone == .after ? 1 : 0), replacing: zone == .replace, room: workspace.wideRoom),
                  let index = next.panes.firstIndex(of: pane), index < workspace.wideRoom else { return nil }
            return WideDropTarget(column: column, zone: zone, pane: pane, next: next)
        }
        return landing(zone) ?? (fresh ? nil : landing(.replace))
    }

    private static let standIn = SessionRoute(id: UUID())
}

extension View {
    /// 拖起它时告诉宽屏主区拖的是哪一块（`Workspace.dragging`），落点按它预演放下后的样子：iPad 拖着时读不到拖的内容（UIKit 只在放下时给）。
    /// 拖着时别的要跟着起止的经 `also` 一起报：一个视图上叠两个 `onDragSessionUpdated`，iOS 只调里面那个（iPadOS 27 实测）。
    func reportsWideDrag(_ drag: WideDrag, also: @escaping (_ dragging: Bool) -> Void = { _ in }) -> some View {
        modifier(WideDragReport(drag: drag, also: also))
    }
}

private struct WideDragReport: ViewModifier {
    let drag: WideDrag
    let also: (Bool) -> Void
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.onDragSessionUpdated { session in
            let dragging = switch session.phase {
            case .initial, .active: true
            default: false
            }
            workspace.dragging = dragging ? drag : .unknown
            also(dragging)
        }
    }
}

extension WideDrop {
    static func pane(_ type: UTType, _ data: Data, window: UUID, workspace: Workspace) throws -> WideNavigation.Pane? {
        let decoder = JSONDecoder()
        switch type {
        case DraggedColumn.type:
            let value = try decoder.decode(DraggedColumn.self, from: data)
            switch value.piece {
            case .session(let recordID, let sessionID): return .session(SessionRoute(id: recordID, sessionID: sessionID))
            case .card(let id): return .card(id)
            case .page: return value.windowID == window ? workspace.pageRoute.map { .page($0) } : nil
            }
        case .cuepadSession:
            let value = try decoder.decode(DraggedSession.self, from: data)
            return .session(SessionRoute(id: SessionState.recordID(sessionID: value.sessionID), sessionID: value.sessionID))
        default:
            switch try decoder.decode(DraggedCard.self, from: data) {
            case .idea(let id): return .card(id)
            case .session(let sessionID): return .session(SessionRoute(id: SessionState.recordID(sessionID: sessionID), sessionID: sessionID))
            case .task: return nil
            }
        }
    }

    @discardableResult static func apply(_ pane: WideNavigation.Pane, _ target: WideDropTarget, workspace: Workspace) -> Bool {
        workspace.drop(pane, at: target.column.index + (target.zone == .after ? 1 : 0), replacing: target.zone == .replace)
    }

    /// 拖着离开一块：下一块的进入可能先到也可能后到，下一圈还是这一块的才收（不然从一块挪到另一块时占位先消失再出现）。
    static func leave(_ column: Workspace.Column, workspace: Workspace) {
        Task { @MainActor in if workspace.dropTarget?.column == column { workspace.dropTarget = nil } }
    }
}

#if os(iOS)
extension WideColumnController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        guard pane else { return false }
        return session.hasItemsConforming(toTypeIdentifiers: WideDrop.types.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        let types = Set(WideDrop.types.filter { session.hasItemsConforming(toTypeIdentifiers: [$0.identifier]) })
        let column = slot?.column
        let onPage = types.contains(.cuepadCard) && column.flatMap { workspace.pane(in: $0)?.page } != nil
        let taken = pass(onPage ? pageDrop(beside: interaction, session) : nil, session)
        let target = taken == nil ? column.flatMap { WideDrop.target(types, at: session.location(in: view).x / max(1, view.bounds.width - dropUnder), in: $0, workspace: workspace) } : nil
        if workspace.dropTarget != target { workspace.dropTarget = target }
        return taken ?? UIDropProposal(operation: target == nil ? .cancel : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        stopPassing(session)
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        if let page = passedDrop?.interaction { page.delegate?.dropInteraction?(page, sessionDidEnd: session) }
        passedDrop = nil
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    /// 同一个视图上有几个接收器时 UIKit 只问其中一个（iPadOS 27 实测：页的托管视图上 SwiftUI 的接收器与这里加的并存，整场只问这里的），
    /// 这里答"不接"也不会再去问别的。所以页里自己的落点由这里转着问：同一个视图上 SwiftUI 的那个接收器（它不答 canHandle，UIKit 当作能接）。
    private func pageDrop(beside ours: UIDropInteraction, _ session: any UIDropSession) -> UIDropInteraction? {
        ours.view?.interactions.lazy.compactMap { $0 as? UIDropInteraction }.first { other in
            guard other !== ours, let delegate = other.delegate else { return false }
            return delegate.dropInteraction?(other, canHandle: session) ?? true
        }
    }

    private func pass(_ page: UIDropInteraction?, _ session: any UIDropSession) -> UIDropProposal? {
        if let passed = passedDrop?.interaction, passed !== page { passed.delegate?.dropInteraction?(passed, sessionDidExit: session) }
        guard let page, let delegate = page.delegate else {
            passedDrop = nil
            return nil
        }
        if passedDrop?.interaction !== page { delegate.dropInteraction?(page, sessionDidEnter: session) }
        let proposal = delegate.dropInteraction?(page, sessionDidUpdate: session)
        let takes = proposal.map { $0.operation != .cancel && $0.operation != .forbidden } ?? false
        passedDrop = (page, takes)
        return takes ? proposal : nil
    }

    private func stopPassing(_ session: any UIDropSession) {
        if let page = passedDrop?.interaction { page.delegate?.dropInteraction?(page, sessionDidExit: session) }
        passedDrop = nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        if let passed = passedDrop {
            passedDrop = nil
            if passed.takes {
                passed.interaction.delegate?.dropInteraction?(passed.interaction, performDrop: session)
                return
            }
            passed.interaction.delegate?.dropInteraction?(passed.interaction, sessionDidExit: session)
        }
        let target = workspace.dropTarget
        workspace.dropTarget = nil
        guard let target, target.column == slot?.column, let provider = session.items.first?.itemProvider,
              let type = WideDrop.types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return }
        load(provider, type) { [workspace] result in
            do {
                if let pane = try result.get() { WideDrop.apply(pane, target, workspace: workspace) }
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func load(_ provider: NSItemProvider, _ type: UTType, _ done: @escaping @MainActor (Result<WideNavigation.Pane?, any Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [workspace, window = focus.windowID] data, error in
            Task { @MainActor in
                done(Result {
                    if let error { throw error }
                    return try WideDrop.pane(type, data ?? Data(), window: window, workspace: workspace)
                })
            }
        }
    }
}
#endif

struct WideDropFeedback: View {
    let window: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var last: WideMetrics.Span?

    var body: some View {
        let span = workspace.dropTarget.flatMap { WideMetrics(width: window, workspace: workspace, navigation: $0.next).spans[WideMetrics.Piece($0.pane)] }
        let shown = span ?? last
        RoundedRectangle(cornerRadius: Radius.sheet)
            .fill(palette.selection)
            .glass(in: RoundedRectangle(cornerRadius: Radius.sheet), ink: .clear)
            .padding(Spacing.item)
            .frame(width: shown?.width ?? 0)
            .offset(x: shown?.origin ?? 0)
            .opacity(span == nil ? 0 : 1)
            .scaleEffect(span == nil ? 0.97 : 1)
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: span)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, Chrome.band)
            .onChange(of: span) { if let span { last = span } }
            .allowsHitTesting(false)
            .readerHidden(true)
    }
}
