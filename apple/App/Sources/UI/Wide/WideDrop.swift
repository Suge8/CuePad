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

/// 宽屏主区接的拖放（Mac 的 `WideColumnView`、iPad 的 `WideColumnController`）：会话（栏头的名字、会话条的行、带会话的看板卡）与灵感（卡、灵感那一块的栏头）。
/// 拖着时只看得到类型、读不到内容，落点只按类型定：带会话的就当会话，只带卡的当灵感（不带会话的任务卡放下时不接）。
enum WideDrop {
    static let types: [UTType] = [DraggedColumn.type, .cuepadSession, .cuepadCard]

    /// 拖到第 `column` 块、横向在它宽的 `fraction` 处：两侧各四分之一是插在旁边，中间是换掉它；nil 不接。
    /// 主区不是会话时只有主区那一块接会话（开到主区；盖着一条灵感时会话开在左边、灵感挪到它右边），灵感卡的落点归页里（项目页、看板）。
    /// 最左只能是会话：灵感拖到最左那块上只插在它右边。窗口放满了（`wideRoom`）只能换：插进来会挤掉最右那块，占位却在别处，看不出谁会没了。
    static func zone(_ types: Set<UTType>, at fraction: CGFloat, in column: Workspace.Column, workspace: Workspace) -> WideDropZone? {
        let session = types.contains(DraggedColumn.type) || types.contains(.cuepadSession)
        guard session || types.contains(.cuepadCard) else { return nil }
        guard workspace.session(in: .main) != nil else {
            guard session, column == .main else { return nil }
            return workspace.openCard != nil ? .before : .replace
        }
        let full = 1 + workspace.beside.count >= workspace.wideRoom
        if !session, column == .main { return full ? nil : .after }
        if full { return .replace }
        return fraction < 0.25 ? .before : fraction > 0.75 ? .after : .replace
    }

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

    static func apply(_ pane: WideNavigation.Beside, _ zone: WideDropZone, in column: Workspace.Column, workspace: Workspace) {
        workspace.drop(pane, at: column.index + (zone == .after ? 1 : 0), replacing: zone == .replace)
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
        drop.zone = slot.column.flatMap { zone(session, in: $0) }
        return UIDropProposal(operation: drop.zone == nil ? .cancel : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) { drop.zone = nil }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) { drop.zone = nil }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        defer { drop.zone = nil }
        guard let column = slot.column, let zone = drop.zone, let provider = session.items.first?.itemProvider,
              let type = WideDrop.types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            Task { @MainActor in
                do {
                    if let error { throw error }
                    if let pane = try WideDrop.pane(type, data ?? Data()) { WideDrop.apply(pane, zone, in: column, workspace: self.workspace) }
                } catch {
                    self.workspace.fail(error)
                }
            }
        }
    }

    private func zone(_ session: any UIDropSession, in column: Workspace.Column) -> WideDropZone? {
        let types = Set(WideDrop.types.filter { session.hasItemsConforming(toTypeIdentifiers: [$0.identifier]) })
        return WideDrop.zone(types, at: session.location(in: view).x / max(1, view.bounds.width - drop.under), in: column, workspace: workspace)
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
                WideTitleDrag(title: title, type: DraggedColumn.type, item: DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID))
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

@Observable
final class WideDropState {
    var zone: WideDropZone?
    @ObservationIgnored var under: CGFloat = 0
}

/// 拖着经过一块时，放下后新的一块会在哪：一块透明的玻璃占位浮在那里，底下的页透出来（插在旁边占这一块靠那边的一半，换掉它占整块），
/// 指针在两侧与中间之间挪时占位连续地伸缩滑过去，不跳。
struct WideDropFeedback: View {
    let state: WideDropState
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - state.under, half = (width / 2).rounded()
            let zone = state.zone
            RoundedRectangle(cornerRadius: Radius.sheet)
                .fill(palette.selection)
                .glass(in: RoundedRectangle(cornerRadius: Radius.sheet), ink: .clear)
                .padding(Spacing.item)
                .frame(width: zone == .replace ? width : half)
                .offset(x: zone == .after ? width - half : 0)
                .opacity(zone == nil ? 0 : 1)
                .scaleEffect(zone == nil ? 0.97 : 1)
                .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: zone)
        }
        .padding(.top, Chrome.band)
        .allowsHitTesting(false)
        .readerHidden(true)
    }
}
