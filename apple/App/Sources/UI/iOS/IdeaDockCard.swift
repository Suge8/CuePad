#if os(iOS)
import CueStore
import CueText
import SwiftUI

struct IdeaDockCard: View {
    let dock: IdeaDock
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.chatHeight) private var chatHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var card: Card?
    @State private var editing: CardEditing?

    private static let head = FloatingHeaderLayout.height

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.head / 2)
        VStack(spacing: 0) {
            head
            if let card, let editing {
                CardTextField(card: card, editing: editing, theme: .inspiration(palette, horizontalInset: Spacing.block), editable: dock.open)
                    .modifier(OpenHeight(height: dock.open ? editorHeight : 0))
                    .readerHidden(!dock.open)
            }
        }
        .clipShape(shape)
        .glass(in: shape)
        .ideaEditing(dock.card, card: $card, editing: $editing, gone: undock)
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in
            if dock.open, editing?.handle.focused != true { show(open: false) }
        }
    }

    private var editorHeight: CGFloat {
        guard chatHeight.isFinite else { return 0 }
        return max(0, chatHeight / 2 - Self.head - Spacing.item)
    }

    private var head: some View {
        HStack(spacing: Spacing.item) {
            Button { show(open: !dock.open) } label: {
                HStack(spacing: Spacing.glyph) {
                    Image(.idea).foregroundStyle(palette.ink3)
                    Text(verbatim: CueSummary.title(of: editing?.text ?? card?.body ?? ""))
                        .font(Typography.secondary.weight(.medium))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, ControlSize.regular.padding)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(DragGesture(minimumDistance: 12).onEnded { drag in
                if drag.translation.height < -Self.pull { show(open: true) }
                if drag.translation.height > Self.pull { show(open: false) }
            })
            .accessibilityHint(dock.open ? "收起" : "展开")
            Button("关闭", icon: .close) { undock() }
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                .help(Text("关闭"))
                .padding(.trailing, Spacing.tight)
        }
        .frame(height: Self.head)
    }

    private static let pull: CGFloat = 24

    private func show(open: Bool) {
        guard dock.open != open else { return }
        var next = dock
        next.open = open
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { workspace.setDock(next) }
    }

    private func undock() {
        if workspace.ideaDock?.card == dock.card { workspace.setDock(nil) }
    }
}

private struct OpenHeight: ViewModifier, Animatable {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(maxHeight: height, alignment: .top)
    }
}
#endif
