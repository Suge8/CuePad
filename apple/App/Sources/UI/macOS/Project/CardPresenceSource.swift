#if os(macOS)
import SwiftUI

extension View {
    func cardPresence(_ id: UUID, in workspace: Workspace) -> some View {
        modifier(CardPresenceSource(card: id, presence: workspace.presses.presence(of: id), workspace: workspace))
    }
}

extension EnvironmentValues {
    @Entry var cardHeld = false
    @Entry var cardSelected = false
}

private struct CardPresenceSource: ViewModifier {
    let card: UUID
    let presence: CardPresence
    let workspace: Workspace

    func body(content: Content) -> some View {
        content
            .environment(\.cardHeld, presence.held)
            .environment(\.cardSelected, presence.selected)
            .onHover { workspace.presses.hover(card, inside: $0) }
    }
}
#endif
