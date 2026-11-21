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

/// 拖进主区的一块上放下会怎样：插在这一块左边、右边，或换掉它。
enum WideDropZone: Equatable {
    case before, replace, after
}

/// 拖着经过主区时放下会怎样：落在哪一块的哪一边、放下后导航成什么样（占位按它画，`WideDropFeedback`）。每个窗口一份（`Workspace.dropTarget`）。
struct WideDropTarget: Equatable {
    let column: Workspace.Column
    let zone: WideDropZone
    let pane: WideNavigation.Beside
    let next: WideNavigation
}

/// 一块接拖放时这次拖的是什么（`drag` 认这一次：Mac 的拖动序号）。`pane` 读出来前为 nil，读出来不是主区接的（任务卡）为 `.some(nil)`。
final class WideDropState {
    var drag: Int?
    var pane: WideNavigation.Beside??
    /// 右端压在 Cue 浮板下面多宽：落点只按露出来的那截算。
    var under: CGFloat = 0
}

/// 宽屏主区接的拖放（Mac 的 `WideColumnView`、iPad 的 `WideColumnController`）：会话（栏头的名字、会话条的行、带会话的看板卡）与灵感（卡、灵感那一块的栏头）。
/// 拖着时只看得到类型、读不到内容，落点只按类型定：带会话的就当会话，只带卡的当灵感（不带会话的任务卡放下时不接）。
enum WideDrop {
    static let types: [UTType] = [DraggedColumn.type, .cuepadSession, .cuepadCard]

    /// 拖到第 `column` 块、横向在它宽的 `fraction` 处：两侧各四分之一是插在旁边，中间是换掉它；放不了、放了不变、放下后藏起来的不接（nil）。
    /// 主区不是会话时只有主区那一块接会话，灵感卡的落点归页里（项目页、看板）；最左那块被一条灵感盖着时会话放上去就是边聊边看（`WideNavigation.dropping`）。
    /// 最左只能是会话：灵感拖到最左那块上只插在它右边。看得见的放满了（`wideShown`）只能换：插进来会挤掉最右那块，占位却在别处，看不出谁会没了。
    /// `dragged` 读出来之前按类型拿一块新的顶替（只差在已在主区的那块是挪过去）。
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
        // 看板、项目页的卡片落点在主区浏览页里，与这个接收器挂在同一个托管视图上：主区不是会话时带卡片的拖放（有会话的任务卡也带会话）归它们
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

/// 排在窗口最顶那一排（`Chrome.band`），左右让出多少由主区给（`headInset`：收起的 Cue 钮压在最右那一块的栏头上）。
struct WideSessionTitle: View {
    let title: String
    /// 会话所在的项目，写在名字前面，点它去那个项目的页（同项目页栏头里的"项目"回列表）。
    let project: Project?
    /// 栏头平时只写名字；已结束是这一页与在跑的会话唯一的不同，名字后面标出来。
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
            // 每块的栏头末端各一颗玻璃圆钮，同一个样子：最左那块开合活预览（会话有页面可看时；开着是强调色，收起它只有这一处），右边的收起这一块。
            // 最左那块没有收起：它就是主区此刻的页，换去处靠会话条
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

    /// 名字那一块是浮在对话上的玻璃胶囊（同手机页头中间那块），对话从它下面滑过去。
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

/// 会话栏头末端的玻璃圆钮（对话从下面滑过，不带框的钮压在字上看不清）：平时次要色，开着的开关是强调色。
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
    /// 主区右端压在 Cue 浮板下面多宽（宽屏的根给）。别的页整页让出它；看板只按让出后的宽分列，放不下横滑时列滑到浮板下面。
    @Entry var underCue: CGFloat = 0
}

/// 拖着经过主区时，放下后那一块会在哪、多宽：按放下后的导航排一遍（`WideMetrics` 的 `navigation`），一块透明的玻璃占位浮在那里、底下的页透出来。
/// 插进来时别的几块会让窄，占位就是让完之后它的位置与宽，不是指针下那一块的一半。指针在几个落点之间挪时占位连续地伸缩滑过去，不跳；收起时在原处淡出。
/// 排在宽屏的根上（`MainWindow`、`SplitRoot`）：插在两块之间的占位横跨两块，挂在一块里会被那一块的框裁掉。
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
