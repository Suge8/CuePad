#if os(iOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
}

/// 打开的灵感：一整张纸页（宽 iPad 上是居中的纸，两侧露出桌面），正文编辑（`CardTextField`）与自动保存（`CardEditing`）在这里；
/// 顶栏是共用的悬浮顶栏——中间写所属项目与"时间 · 置顶"，右边"⋯"里是分享与 `CardMenu.more`。任务不进这里，在任务气泡里看（`TaskBubble`）。
/// 灵感离开时什么都没写就不留下（`Workspace.leaveEditing`）。
struct CardEditorScreen: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: EditorData?
    @State private var editing: CardEditing?

    private static let pageWidth: CGFloat = 760
    /// 宽屏的纸四边留白同宽：首行不顶着纸边。
    private static let paperInset: CGFloat = 44

    var body: some View {
        editor
            .frame(maxWidth: wide ? Self.pageWidth : .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper, in: .rect(cornerRadius: wide ? 22 : 0, style: .continuous))
            .overlay {
                if wide { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hair).allowsHitTesting(false) }
            }
            .padding(wide ? EdgeInsets(top: 8, leading: 24, bottom: 0, trailing: 24) : EdgeInsets())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingHeader(.verbatim(data?.project?.shownName ?? ""), detail: data.map(detail)) { actions }
            .observing(services.store, id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
                guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
                return EditorData(card: card, project: try store.project(card.projectID))
            }
            .onChange(of: data?.card.id, initial: true) {
                guard editing == nil, let card = data?.card else { return }
                editing = CardEditing(card, workspace: workspace)
            }
            .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { dismiss() } }
            .onDisappear { editing?.leave() }
    }

    private var wide: Bool { sizeClass == .regular }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let editing {
                CardTextField(card: data.card, editing: editing, theme: wide ? .editor(palette, horizontalInset: Self.paperInset, verticalInset: Self.paperInset) : .editor(palette, horizontalInset: 20))
            }
        }
    }

    /// 顶栏的一行："改于 03:36 · 置顶"。
    private func detail(_ data: EditorData) -> Dotted {
        Dotted(String(localized: "改于 \(DateLabel.short(data.card.modifiedAt))"), data.card.isPinned ? String(localized: "已置顶") : nil)
    }

    /// 顶栏右边的"⋯"：从第一帧就在（卡片还没读到时禁用），随放大过渡一起出现，不在过渡结束后才弹出来。
    private var actions: some View {
        Menu("更多", icon: .more) {
            if let card = data?.card {
                ShareLink(item: outgoing(card)) { Label("分享", icon: .share) }
                Divider()
                CardActions(card: card, more: true)
            }
        }
        .disabled(data == nil)
    }

    /// 当前编辑中的整张正文（未保存的也算），变量已填：从编辑器读，不读跟着每个字更新的 `CardEditing.text`——读了就是每敲一个字整页重算一遍。
    private func outgoing(_ card: Card) -> String {
        Outgoing.text(body: editing.map { $0.handle.text ?? $0.initialText } ?? card.body, values: card.variableValues)
    }
}
#endif
