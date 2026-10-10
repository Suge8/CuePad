#if os(macOS)
import SwiftUI

extension View {
    /// 纸页开合的原卡片：被纸盖住时隐去，被打开期间把位置报给纸页（见 `CardPresence`）；Mac 上报鼠标进出，按下时据此知道按的是哪张卡。
    func cardPresence(_ id: UUID, in workspace: Workspace) -> some View {
        modifier(CardPresenceSource(card: id, presence: workspace.presence(of: id), workspace: workspace))
    }
}

extension EnvironmentValues {
    /// 这张卡显出按下：鼠标按着，或刚被打开、纸页还在准备（见 `CardOpenStyle`）。
    @Entry var cardHeld = false
}

/// 单独的修饰器：只有它读这张卡的开合状态，卡片本身的内容不随开合重算。
private struct CardPresenceSource: ViewModifier {
    let card: UUID
    let presence: CardPresence
    let workspace: Workspace

    func body(content: Content) -> some View {
        content
            .environment(\.cardHeld, presence.held)
            .opacity(presence.covered ? 0 : 1)
            .onHover { workspace.hover(card, inside: $0) }
            .background {
                // 只在被打开期间挂上位置读取；放在背景里，增减它不改变卡片本身的身份
                if presence.isTracked {
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { presence.frame = $0 }
                }
            }
    }
}
#endif
