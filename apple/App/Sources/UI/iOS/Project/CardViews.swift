#if os(iOS)
import SwiftUI

struct IdeaTile: View {
    let entry: CardEntry
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let card = entry.card
        NavigationLink(value: Route.card(card.id)) {
            IdeaTileFace(entry: entry, floated: floated)
                .note()
                .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(PressStyle(.card))
        .zoomSource(card.id, in: zoom)
        .rowSwipes(.card(card, workspace: workspace), clipped: false)
        .contextMenu { CardActions(card: card) }
        .cardDraggable(.idea(card.id), shape: .rect(cornerRadius: Radius.card))
    }
}
#endif
