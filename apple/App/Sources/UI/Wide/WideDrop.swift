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

#if os(iOS)
extension WideColumnController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        // 看板、项目页的卡片落点在主区浏览页里，与这个接收器挂在同一个托管视图上：带卡片的拖放（有会话的任务卡也带会话）归它们，不在这里打开会话
        if slot == .main, workspace.session(in: .main) == nil, session.hasItemsConforming(toTypeIdentifiers: [UTType.cuepadCard.identifier]) { return false }
        return session.hasItemsConforming(toTypeIdentifiers: [DraggedColumn.type.identifier, UTType.cuepadSession.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        drop.targeted = true
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) { drop.targeted = false }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) { drop.targeted = false }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        drop.targeted = false
        guard let column = slot.column, let provider = session.items.first?.itemProvider else { return }
        if provider.hasItemConformingToTypeIdentifier(DraggedColumn.type.identifier) {
            load(DraggedColumn.self, type: DraggedColumn.type, from: provider) {
                self.workspace.dropSession(SessionRoute(id: $0.recordID, sessionID: $0.sessionID), in: column, movingWithinWindow: $0.windowID == self.focus.windowID)
            }
        } else {
            load(DraggedSession.self, type: .cuepadSession, from: provider) {
                self.workspace.openSession(PiSessionState.recordID(sessionID: $0.sessionID), sessionID: $0.sessionID, in: column)
            }
        }
    }

    private func load<Value: Decodable & Sendable>(_ value: Value.Type, type: UTType, from provider: NSItemProvider, apply: @escaping @MainActor (Value) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            let result = Result { () throws -> Value in
                if let error { throw error }
                return try JSONDecoder().decode(value, from: data ?? Data())
            }
            Task { @MainActor in
                switch result {
                case .success(let value): apply(value)
                case .failure(let error): self.workspace.fail(error)
                }
            }
        }
    }
}

#endif

/// 会话的栏头（宽屏主区的一边）：「项目 / 会话名」，项目淡一档，字同各栏栏头的标题（`Typography.toolbarTitle`）；右边 ×（`closeColumn`），
/// 同这一排别的钮一样是玻璃圆钮（`Chrome.control`）。拖标题到主区的另一半换边，松手才改去处。
/// 排在窗口最顶那一排（`Chrome.band`），左右让出多少由主区给（`headInset`：收起的 Cue 钮压在最右那一块的栏头上）。
struct WideSessionTitle: View {
    let title: String
    let project: String?
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.wideWindowID) private var windowID
    @Environment(\.headInset) private var inset
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            if let project {
                Text(verbatim: project).foregroundStyle(palette.ink3).lineLimit(1)
                Text(verbatim: "/").foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            if let windowID, let session = workspace.session(in: column) {
                #if os(iOS)
                WideTitleDrag(title: title, item: DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID))
                    .frame(maxWidth: .infinity)
                #else
                Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1)
                    .contentShape(.rect)
                    .draggable(DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID))
                    .layoutPriority(1)
                #endif
            }
            Spacer(minLength: 8)
            Button("关闭", icon: .close) { workspace.closeColumn(column) }
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .font(Typography.body)
        }
        .font(Typography.toolbarTitle)
        .accessibilityElement(children: .contain)
        .padding(inset).frame(height: Chrome.band)
        .windowDragArea()
    }
}

extension EnvironmentValues {
    /// 这一块栏头左右让出多少：收起的 Cue 钮压在最右那一块的栏头右端（`MainWindow`、`SplitRoot` 给）。
    @Entry var headInset = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
}

@Observable
final class WideDropState {
    var targeted = false
}

struct WideDropFeedback: View {
    let state: WideDropState
    @Environment(\.palette) private var palette

    var body: some View {
        if state.targeted {
            palette.selection.overlay { Text("放在这里").font(Typography.title) }.allowsHitTesting(false)
        }
    }
}
