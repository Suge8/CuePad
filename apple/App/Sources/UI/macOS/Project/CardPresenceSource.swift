#if os(macOS)
import SwiftUI

extension View {
    /// 墙上能点开的卡：显出按下（`CardPresence`）、报鼠标进出——按下时据此知道按的是哪张卡。
    func cardPresence(_ id: UUID, in workspace: Workspace) -> some View {
        modifier(CardPresenceSource(card: id, presence: workspace.presses.presence(of: id), workspace: workspace))
    }
}

extension EnvironmentValues {
    /// 这张卡显出按下：鼠标按着，或刚被打开、编辑页还在准备（见 `CardOpenStyle`）。
    @Entry var cardHeld = false
    /// 这张卡在批量选择里选上了（`CardPresses`）。
    @Entry var cardSelected = false
}

/// 单独的修饰器：只有它读这张卡的按下与选中状态，卡片本身的内容不随之重算。
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
