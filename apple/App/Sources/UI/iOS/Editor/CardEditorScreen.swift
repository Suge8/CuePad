#if os(iOS)
import CueEditor
import CueStore
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
}

struct CardEditorScreen: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: EditorData?
    @State private var editing: CardEditing?
    @State private var inspirationSharing = InspirationSharing()

    private static let pageWidth: CGFloat = 760

    var body: some View {
        page
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: editing))
            .floatingHeader(.verbatim(data?.project?.shownName ?? ""), idea: workspace.layout == .wide ? cardID : nil, detail: { detail }, trailing: { actions })
            // 卡没了（并进了草稿、接进了会话的回复框）由工作区收起，不当成出错
            .observing(services.store, id: cardID, into: $data, onError: { [workspace] error in
                if case CueStoreError.notFound = error { return }
                workspace.fail(error)
            }) { [cardID] store in
                guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
                return EditorData(card: card, project: try store.project(card.projectID))
            }
            .onChange(of: data?.card.id, initial: true) {
                guard editing == nil, let card = data?.card else { return }
                editing = CardEditing(card, workspace: workspace)
            }
            .onDisappear { editing?.leave() }
    }

    private var wide: Bool { sizeClass == .regular }

    /// 手机上正文铺到屏幕上下边，滚动时从页头的玻璃与横条底下穿过；静止时首行的位置由文字视图把安全区算进滚动边距（`contentInsetAdjustmentBehavior`）给出，同没铺开时一样。
    @ViewBuilder private var page: some View {
        if wide {
            editor
                .frame(maxWidth: Self.pageWidth, maxHeight: .infinity, alignment: .top)
                .background(palette.paper, in: .rect(cornerRadius: Radius.sheet))
                .overlay { RoundedRectangle(cornerRadius: Radius.sheet).strokeBorder(palette.hair).allowsHitTesting(false) }
                .clipShape(.rect(cornerRadius: Radius.sheet))
                .padding(EdgeInsets(top: Spacing.item, leading: Spacing.sheet, bottom: 0, trailing: Spacing.sheet))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let editing {
                CardTextField(card: data.card, editing: editing, theme: .inspiration(palette, horizontalInset: wide ? Spacing.sheet : LibraryLayout.textInset))
            }
        }
    }

    /// 卡片还没读到时这一行先占着位置，读到后标题不上移。
    @ViewBuilder private var detail: some View {
        Group {
            if let card = data?.card {
                EditedLine(marks: EditedLine.Marks(edited: card.modifiedAt, pinned: card.isPinned))
            } else {
                Text(verbatim: " ")
            }
        }
        .font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
    }

    /// 从第一帧就在（卡片还没读到时禁用），随放大过渡一起出现，不在过渡结束后才弹出来。
    @ViewBuilder private var actions: some View {
        ChatAlongsideButton(cardID: cardID, editing: editing)
        Menu("更多", icon: .more) {
            if let card = data?.card, let editing {
                InspirationEditorActions(card: card, editing: editing, sharing: inspirationSharing)
            }
        }
        .disabled(editing == nil)
        .accessibilityLabel("更多")
    }
}
#endif
