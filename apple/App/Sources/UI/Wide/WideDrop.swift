import CueStore
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct DraggedColumn: Codable, Transferable {
    let windowID: UUID
    let recordID: UUID
    let sessionID: String?
    static let type = UTType(exportedAs: "\(AppIdentity.id).column", conformingTo: .data)
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: type) }
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
    let pane: WideNavigation.Beside
    let next: WideNavigation
}

final class WideDropState {
    var drag: Int?
    var pane: WideNavigation.Beside??
    var under: CGFloat = 0
}

/// 宽屏主区接的拖放（Mac 的 `WideColumnView`、iPad 的 `WideColumnController`）：会话（栏头的名字、会话条的行、带会话的看板卡）与灵感（卡、灵感那一块的栏头）。
/// 拖着时只看得到类型、读不到内容，落点只按类型定：带会话的就当会话，只带卡的当灵感（不带会话的任务卡放下时不接）。
enum WideDrop {
    static let types: [UTType] = [DraggedColumn.type, .cuepadSession, .cuepadCard]

    static func target(_ types: Set<UTType>, dragged: WideNavigation.Beside??, at fraction: CGFloat, in column: Workspace.Column, workspace: Workspace) -> WideDropTarget? {
        guard case .wide(let state) = workspace.navigation else { return nil }
        let session = types.contains(DraggedColumn.type) || types.contains(.cuepadSession)
        guard session || types.contains(.cuepadCard) else { return nil }
        let pane: WideNavigation.Beside
        switch dragged {
        case .some(.some(let known)): pane = known
        case .some(.none): return nil
        case .none: pane = session ? .session(standIn) : .card(standIn.id)
        }
        let isSession = if case .session = pane { true } else { false }
        let full = 1 + workspace.wideShown >= workspace.wideRoom
        let zone: WideDropZone
        if state.mainSession == nil || column == .main && isSession && workspace.openCard != nil {
            guard isSession, column == .main else { return nil }
            zone = .replace
        } else if column == .main && !isSession {
            guard !full else { return nil }
            zone = .after
        } else {
            zone = full ? .replace : fraction < 0.25 ? .before : fraction > 0.75 ? .after : .replace
        }
        guard let next = state.dropping(pane, at: column.index + (zone == .after ? 1 : 0), replacing: zone == .replace, room: workspace.wideRoom, covering: workspace.openCard),
              let index = next.panes.firstIndex(of: pane), index < workspace.wideRoom else { return nil }
        return WideDropTarget(column: column, zone: zone, pane: pane, next: next)
    }

    private static let standIn = SessionRoute(id: UUID())
}

extension View {
    /// 拖起它时告诉宽屏主区拖的是哪一块（`Workspace.dragging`）：iPad 拖着时读不到拖的内容（UIKit 只在放下时给），落点按它预演放下后的样子。
    /// Mac 拖着时就读得出剪贴板（`WideColumnView`），不用报。`.some(nil)` 是主区不接的（任务卡）。
    @ViewBuilder func reportsWideDrag(_ pane: WideNavigation.Beside??) -> some View {
        #if os(iOS)
        modifier(WideDragReport(pane: pane))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WideDragReport: ViewModifier {
    let pane: WideNavigation.Beside??
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
    static func pane(_ type: UTType, _ data: Data) throws -> WideNavigation.Beside? {
        let decoder = JSONDecoder()
        switch type {
        case DraggedColumn.type:
            let value = try decoder.decode(DraggedColumn.self, from: data)
            return .session(SessionRoute(id: value.recordID, sessionID: value.sessionID))
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

    @discardableResult static func apply(_ pane: WideNavigation.Beside, _ target: WideDropTarget, workspace: Workspace) -> Bool {
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
        guard slot.column != nil, workspace.session(in: .main) != nil || !session.hasItemsConforming(toTypeIdentifiers: [UTType.cuepadCard.identifier]) else { return false }
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

    private func load(_ provider: NSItemProvider, _ type: UTType, _ done: @escaping @MainActor (Result<WideNavigation.Beside?, any Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            Task { @MainActor in
                done(Result {
                    if let error { throw error }
                    return try WideDrop.pane(type, data ?? Data())
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

struct WideSessionTitle: View {
    let title: String
    let project: Project?
    var ended = false
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.wideWindowID) private var windowID
    @Environment(\.headInset) private var inset
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            name
            Spacer(minLength: Spacing.item)
            if column == .main {
                if let session = workspace.session(in: .main) { LivePreviewTool(session: session) }
            } else {
                HeadTool(label: "收起并排", icon: .rightColumn) { workspace.closeColumn(column) }
            }
        }
        .accessibilityElement(children: .contain)
        .padding(inset).frame(height: Chrome.band)
        .windowDragArea()
    }

    private var name: some View {
        HStack(spacing: Spacing.glyph) {
            if let project {
                Button { workspace.select(.project(project.id)) } label: { Text(verbatim: project.shownName).lineLimit(1) }
                    .buttonStyle(PressStyle(.inline))
                    .foregroundStyle(palette.ink3)
                Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
            }
            if let windowID, let session = workspace.session(in: column) {
                #if os(iOS)
                WideTitleDrag(title: title, type: DraggedColumn.type, item: DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID), pane: .session(session))
                    .layoutPriority(1)
                #else
                Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1)
                    .contentShape(.rect)
                    .draggable(DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID))
                    .layoutPriority(1)
                #endif
            }
            if ended {
                HStack(spacing: Spacing.tight) {
                    Image(.ended).readerHidden(true)
                    Text(SessionShown(status: .ended).label)
                }
                    .font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1).fixedSize()
                    .padding(.leading, Spacing.tight)
                    .transition(.opacity)
            }
        }
        .font(Typography.toolbarTitle)
        .animation(Motion.fade, value: ended)
        .padding(.horizontal, Spacing.block)
        .frame(height: Chrome.control)
        .glass(in: .capsule)
    }
}

struct HeadTool: View {
    let label: LocalizedStringResource
    let icon: Icon
    var on = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { Image(icon).foregroundStyle(on ? palette.signature : palette.ink2) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .toggledOn(on)
            .help(Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension EnvironmentValues {
    @Entry var headInset = EdgeInsets(top: 0, leading: Spacing.page, bottom: 0, trailing: Spacing.page)
    @Entry var underCue: CGFloat = 0
}

struct WideDropFeedback: View {
    let window: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var last: WideMetrics.Span?

    var body: some View {
        let span = workspace.dropTarget.flatMap { WideMetrics(width: window, workspace: workspace, navigation: $0.next).spans[$0.pane] }
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
