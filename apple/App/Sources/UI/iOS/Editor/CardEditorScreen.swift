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
    private static let paperInset: CGFloat = 44

    var body: some View {
        editor
            .frame(maxWidth: wide ? Self.pageWidth : .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper, in: .rect(cornerRadius: wide ? Radius.sheet : 0))
            .overlay {
                if wide { RoundedRectangle(cornerRadius: Radius.sheet).strokeBorder(palette.hair).allowsHitTesting(false) }
            }
            .clipShape(.rect(cornerRadius: wide ? Radius.sheet : 0))
            .padding(wide ? EdgeInsets(top: Spacing.item, leading: Spacing.sheet, bottom: 0, trailing: Spacing.sheet) : EdgeInsets())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: editing))
            .floatingHeader(.verbatim(data?.project?.shownName ?? ""), detail: data.map(detail)) { actions }
            .observing(services.store, id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
                guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
                return EditorData(card: card, project: try store.project(card.projectID))
            }
            .onChange(of: data?.card.id, initial: true) {
                guard editing == nil, let card = data?.card else { return }
                editing = CardEditing(card, workspace: workspace)
            }
            .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { workspace.leave(.card(cardID)) } }
            .onDisappear { editing?.leave() }
    }

    private var wide: Bool { sizeClass == .regular }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let editing {
                CardTextField(card: data.card, editing: editing, theme: .inspiration(palette, horizontalInset: wide ? Self.paperInset : 20))
            }
        }
    }

    private func detail(_ data: EditorData) -> Dotted {
        Dotted(String(localized: "改于 \(DateLabel.short(data.card.modifiedAt))"), data.card.isPinned ? String(localized: "已置顶") : nil)
    }

    /// 从第一帧就在（卡片还没读到时禁用），随放大过渡一起出现，不在过渡结束后才弹出来。
    private var actions: some View {
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
