#if os(macOS)
import SwiftUI

/// Mac 浮层顶上一行：标题居中，右上一颗关闭（Esc 同）；`trailing` 在关闭钮左边（如"展开编辑"）。
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    /// 标题两侧各让出右上那一组钮（"展开编辑"与关闭）的宽：标题仍在正中，长了截断、不压到钮下面。
    private static var buttonRoom: CGFloat { 96 }
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .padding(.horizontal, Self.buttonRoom)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .trailing) {
                HStack(spacing: Spacing.item) {
                    trailing
                    PanelCloseButton()
                }
                .padding(.trailing, Spacing.block)
            }
    }
}

/// Mac 浮层右上的关闭钮（Esc 同）。
struct PanelCloseButton: View {
    @Environment(\.closePanel) private var close

    var body: some View {
        Button("关闭", icon: .close) { close() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .round, size: .compact))
            .help("关闭（Esc）")
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

extension View {
    func panelFieldSurface() -> some View { modifier(PanelFieldSurface()) }
}

private struct PanelFieldSurface: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.background(palette.fill, in: .rect(cornerRadius: Radius.block))
    }
}

/// Mac 浮层里占满一行的搜索框，弹出即聚焦。
struct PanelSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            Image(.search).foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $text, palette: palette).textFieldStyle(.plain).focused($focused)
        }
        .font(Typography.body)
        .padding(.horizontal, Spacing.group).frame(height: 34)
        .panelFieldSurface()
        .padding(.horizontal, Spacing.panel)
        .onAppear { focused = true }
    }
}
#endif
