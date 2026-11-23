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

    var body: some View {
        page
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: editing))
            .floatingHeader(.verbatim(data?.project?.shownName ?? ""), detail: { detail }, trailing: { actions })
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

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let editing {
                CardTextField(card: data.card, editing: editing, theme: .inspiration(
                    palette, horizontalInset: wide ? Spacing.page : LibraryLayout.textInset, maxTextWidth: InspirationPaper.textWidth), underHeader: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var detail: some View {
        Group {
            if let card = data?.card {
                EditedLine(edited: card.modifiedAt, pinned: card.isPinned)
            } else {
                Text(verbatim: " ")
            }
        }
        .font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
    }

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
