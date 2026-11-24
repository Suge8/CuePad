#if os(iOS)
import CueEditor
import CueStore
import SwiftUI

struct CardEditorScreen: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var card: Card?
    @State private var editing: CardEditing?
    @State private var inspirationSharing = InspirationSharing()

    var body: some View {
        page
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: editing))
            .floatingHeader(.verbatim(editing?.title ?? "")) {
                if let card, let editing { InspirationEditorActions(card: card, editing: editing, sharing: inspirationSharing) }
            } detail: {
                detail
            } trailing: {
                ChatAlongsideButton(cardID: cardID, editing: editing)
            }
            .ideaEditing(cardID, card: $card, editing: $editing) { [workspace, cardID] in workspace.leave(.card(cardID)) }
    }

    private var wide: Bool { sizeClass == .regular }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let card, let editing {
                CardTextField(card: card, editing: editing, theme: .inspiration(
                    palette, horizontalInset: wide ? Spacing.page : LibraryLayout.textInset, maxTextWidth: InspirationPaper.textWidth), underHeader: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var detail: some View {
        Group {
            if let card {
                EditedLine(edited: card.modifiedAt, pinned: card.isPinned)
            } else {
                Text(verbatim: " ")
            }
        }
        .font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
    }
}
#endif
