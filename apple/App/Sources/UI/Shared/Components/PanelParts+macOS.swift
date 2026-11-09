#if os(macOS)
import SwiftUI

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
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
