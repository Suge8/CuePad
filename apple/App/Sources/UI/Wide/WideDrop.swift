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

final class WideDropState {
    var drag: Int?
    var pane: WideNavigation.Pane??
    var under: CGFloat = 0
}

/// 宽屏主区接的拖放（Mac 的 `WideColumnView`、iPad 的 `WideColumnController`）：每一块的胶囊（`PaneTitle`）、会话条的行、带会话的看板卡、灵感卡。
/// 落在一块的左右四分之一插在它旁边，正中换掉它；放满了只能换。独占的页（进展）只能换掉。
/// 已在这一排的是挪位置：落在别的块上哪里都有结果，插过去位置没变（本来就挨着）就与那一块对调。
/// 从页里拖起的卡（带 `.cuepadCard`：看板的气泡、任务行、灵感卡）在页上只有右边四分之一是"拖出去并排"（放满了是换掉这一页），
/// 其余归页自己、主区不接：任务行与卡都靠左排，排序、灵感拖到任务上的落点在左边与正中；位置按落点先判，不看放没放满。
/// 进展不能并排，整页归它，气泡在上面怎么拖都是换列。灵感卡是拿来并排看的，落在别的块正中也放到那一块右边，放满了才换。
/// 拖着时只看得到类型、读不到内容，落点只按类型定：带会话的就当会话，只带卡的当灵感（不带会话的任务卡放下时不接）。
enum WideDrop {
    static let types: [UTType] = [DraggedColumn.type, .cuepadSession, .cuepadCard]

    static func target(_ types: Set<UTType>, dragged: WideNavigation.Pane??, at fraction: CGFloat, in column: Workspace.Column, workspace: Workspace) -> WideDropTarget? {
        guard case .wide(let state) = workspace.navigation, let over = workspace.pane(in: column) else { return nil }
        let session = types.contains(DraggedColumn.type) || types.contains(.cuepadSession)
        guard session || types.contains(.cuepadCard) else { return nil }
        let pane: WideNavigation.Pane
        switch dragged {
        case .some(.some(let known)): pane = known
        case .some(.none): return nil
        case .none: pane = session ? .session(standIn) : .card(standIn.id)
        }
        guard over != pane else { return nil }
        let fresh = !state.panes.contains(pane)
        let full = fresh && workspace.wideShown >= workspace.wideRoom
        let card = types.contains(.cuepadCard)
        if card, over.page != nil, over.standsAlone || fraction <= 0.75 { return nil }
        var zone: WideDropZone = over.standsAlone || full ? .replace : fraction < 0.25 ? .before : fraction > 0.75 ? .after : .replace
        if zone == .replace, card, pane.card != nil, fresh, !full { zone = .after }
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
    /// 拖起它时告诉宽屏主区拖的是哪一块（`Workspace.dragging`）：iPad 拖着时读不到拖的内容（UIKit 只在放下时给），落点按它预演放下后的样子。
    /// Mac 拖着时就读得出剪贴板（`WideColumnView`），不用报。`.some(nil)` 是主区不接的（任务卡）。
    @ViewBuilder func reportsWideDrag(_ pane: WideNavigation.Pane??) -> some View {
        #if os(iOS)
        modifier(WideDragReport(pane: pane))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WideDragReport: ViewModifier {
    let pane: WideNavigation.Pane??
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active: workspace.dragging = pane
            default: workspace.dragging = nil
            }
        }
    }
}
#endif

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
        guard slot.column != nil else { return false }
        return session.hasItemsConforming(toTypeIdentifiers: WideDrop.types.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        let target = slot.column.flatMap { target(session, in: $0) }
        if workspace.dropTarget != target { workspace.dropTarget = target }
        return UIDropProposal(operation: target == nil ? .cancel : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        if let column = slot.column { WideDrop.leave(column, workspace: workspace) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        if let column = slot.column { WideDrop.leave(column, workspace: workspace) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        let target = workspace.dropTarget
        workspace.dropTarget = nil
        guard let target, target.column == slot.column, let provider = session.items.first?.itemProvider,
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

    private func target(_ session: any UIDropSession, in column: Workspace.Column) -> WideDropTarget? {
        let types = Set(WideDrop.types.filter { session.hasItemsConforming(toTypeIdentifiers: [$0.identifier]) })
        let fraction = session.location(in: view).x / max(1, view.bounds.width - drop.under)
        // UIKit 只在放下时给读拖的内容：拖着时按拖起它的那一头报的（`reportsWideDrag`），别的窗口、别的 App 拖来的按类型猜
        return WideDrop.target(types, dragged: workspace.dragging, at: fraction, in: column, workspace: workspace)
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
