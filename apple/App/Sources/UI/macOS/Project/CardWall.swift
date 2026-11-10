#if os(macOS)
import CueStore
import SwiftUI

struct CardOpenStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.cardHeld) private var held

        var body: some View {
            configuration.label
                .modifier(PressFeedback(pressed: configuration.isPressed || held, kind: .card))
        }
    }
}

/// 单独一个视图：悬停只改卡的外框，卡面不随之重算。
private struct CardFace: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(card.body)
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-Spacing.item).padding(.bottom, Spacing.item)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                Text(text.label)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                AgentDot(card: card.id)
            }
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(Typography.body).lineSpacing(Typography.lineSpacing).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? CardText.previewLines : 2)
            }
            CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated, font: Typography.meta)
                .padding(.top, Spacing.hair)
        }
        .padding(Spacing.block)
    }
}

struct CardTile: View {

    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
        CardFace(card: card, lastTarget: lastTarget, floated: floated)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectedCard())
        .paper()
        .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering, !workspace.presses.isSelecting {
                DeleteCardButton(card: card.id).padding(Spacing.item).transition(.opacity)
            }
        }
        .cardPresence(card.id, in: workspace)
        .cardDraggable(.idea(card.id), shape: .rect(cornerRadius: Radius.card))
        .onHover { hovering = $0 }
        .presetHover($hovering)
        .animation(Motion.fade, value: hovering)
        .contextMenu { CardActions(card: card, selectable: true) }
        .accessibilityElement(children: .combine)
    }

    private func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

struct DeleteCardButton: View {
    let card: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button {
            let id = card
            workspace.attempt { try await workspace.trash(id) }
        } label: {
            DeleteGlyph()
        }
        .buttonStyle(PressStyle(.button))
        .help("删除（⌘⌫），可撤销")
        .accessibilityLabel("删除")
    }
}

private struct DeleteGlyph: View {
    @Environment(\.buttonHovered) private var lit
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.trash)
            .font(Typography.meta.weight(.medium))
            .foregroundStyle(lit ? palette.failure : palette.ink2)
            .frame(width: ControlSize.inline.height, height: ControlSize.inline.height)
            .background(palette.paperLit, in: .circle)
            .overlay(Circle().strokeBorder(palette.hair))
            .elevation(.hover)
            .frame(width: ControlSize.target, height: ControlSize.target)
            .contentShape(.circle)
    }
}

/// 全 App 一套选中（docs/ui.md「视觉原则」），不着靛青。
/// 挂在卡面外、纸里面：底垫在字下，卡面不随选中重算。
private struct SelectedCard: ViewModifier {
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .background {
                if selected { RoundedRectangle(cornerRadius: Radius.card).fill(palette.selection).transition(.opacity) }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    PickedMark().font(Glyph.large) .padding(Spacing.item).transition(.opacity)
                }
            }
    }
}

/// 墨色圆里一个纸色对勾：深色下墨是浅的，勾跟着取纸色才看得见。
struct PickedMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.picked).foregroundStyle(palette.paper, palette.ink).allowsHitTesting(false)
    }
}

#endif
