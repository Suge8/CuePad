#if os(macOS)
import CueStore
import SwiftUI

struct CardMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var opened: Card??
    @State private var inspirationSharing = InspirationSharing()

    var body: some View {
        let card = (opened ?? nil).flatMap { $0.id == workspace.openCard ? $0 : nil }
        Menu { if let card { items(card).labelStyle(.titleAndIcon) } } label: { Image(.more).imageScale(.large) }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .fixedSize()
            .disabled(card == nil)
            .help("更多")
            .accessibilityLabel("更多")
            .padding(.leading, Spacing.item)
            .observing(services.store, id: workspace.openCard, into: $opened, onError: workspace.fail) { [id = workspace.openCard] store in
                try id.flatMap { try store.card($0) }
            }
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: workspace.openCardEditing))
    }

    @ViewBuilder private func items(_ card: Card) -> some View {
        if let editing = workspace.openCardEditing, editing.cardID == card.id {
            InspirationEditorActions(card: card, editing: editing, sharing: inspirationSharing)
        } else { CardActions(card: card, more: true) }
    }
}
#endif
