import SwiftUI

struct Fold<Label: View, Content: View>: View {
    @Binding var open: Bool
    var toggles = true
    var edge = VerticalEdge.top
    var press = Press.inline
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content
    @Environment(\.chatStay) private var stay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if edge == .bottom { held }
            toggle
                // 没有可开的时只是不接点按，不停用：停用的按钮 iOS 整块压淡
                .allowsHitTesting(toggles)
                .accessibilityExpanded(toggles ? open : nil)
            if edge == .top { held }
        }
        .onDisappear { if open { stay?(key, false) } }
    }

    enum Press { case inline, row }

    @ViewBuilder private var toggle: some View {
        let button = Button {
            stay?(key, !open)
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { open.toggle() }
        } label: { label }
        switch press {
        case .inline: button.buttonStyle(PressStyle(.inline))
        case .row: button.buttonStyle(.row)
        }
    }

    private var held: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, Self.hoverRoom).clipped().padding(.horizontal, -Self.hoverRoom)
    }

    private static var hoverRoom: CGFloat { Spacing.item }
}

extension View {
    func fadesEdge(_ edge: VerticalEdge, when folded: Bool) -> some View {
        mask {
            ZStack(alignment: edge == .top ? .top : .bottom) {
                Rectangle()
                LinearGradient(colors: [.clear, .black], startPoint: edge == .top ? .bottom : .top, endPoint: edge == .top ? .top : .bottom)
                    .frame(height: Note.lineHeight).blendMode(.destinationOut).opacity(folded ? 1 : 0)
            }
            .compositingGroup()
        }
    }
}

struct DisclosureChevron: View {
    let open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.expand).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .readerHidden(true)
    }
}
