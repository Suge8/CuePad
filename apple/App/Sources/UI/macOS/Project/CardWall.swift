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

/// 整行点开一张卡、底由行自己画（`row()`）的按钮：按下与开着（`cardHeld`）交给那块底，不再给整行调亮度（`CardOpenStyle`）——
/// 亮度滤镜对半透明的行底和悬停操作垫的实底（`hoverReveal`）调出两个颜色，行尾显出一块方的。
struct RowOpenStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.cardHeld) private var held

        var body: some View {
            configuration.label.environment(\.rowPressed, configuration.isPressed || held)
        }
    }
}

/// 单独一个视图：悬停只改卡的外框，卡面不随之重算。
private struct CardFace: View {
    let card: Card
    let floated: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(card.body), image = text.images.first
        VStack(alignment: .leading, spacing: 0) {
        if let image { Thumbnail(hash: image, height: NoteTile.thumbnail, framed: false) }
        VStack(alignment: .leading, spacing: Spacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                Text(text.label)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(image == nil ? NoteTile.titleLines : 1)
                Spacer(minLength: 0)
                AgentDot(card: card.id)
            }
            // 摘要拿剩下的高，放不下的行截掉；日期那一行贴底
            if image == nil, !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(Typography.body).lineSpacing(Typography.lineSpacing).foregroundStyle(palette.ink2)
                    .lineLimit(CardText.previewLines)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }
            CardMeta(card: card, text: text, floated: floated, font: Typography.meta)
        }
        .padding(Spacing.block)
        }
        .frame(height: NoteTile.height)
        .clipShape(.rect(cornerRadius: Radius.card))
    }
}

struct CardTile: View {

    let card: Card
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            CardFace(card: card, floated: floated)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SelectedCard())
                .note(lifted: hovering)
                .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering, !workspace.presses.isSelecting {
                // 正落在日期那一行行尾置顶记号的位置上
                DeleteCardButton(card: card.id, onNote: true).padding(Spacing.item).transition(.opacity)
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
    /// 在灵感卡上：垫一块与悬停着的卡同色的底，只为盖住行尾的置顶记号，自己看不出来；指针到了它上面才有悬停的底（`PressStyle`）。
    var onNote = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button {
            let id = card
            workspace.attempt { try await workspace.trash(id) }
        } label: {
            DeleteGlyph(onNote: onNote)
        }
        .buttonStyle(PressStyle(.button))
        .help("删除（⌘⌫），可撤销")
        .accessibilityLabel("删除")
    }
}

private struct DeleteGlyph: View {
    @Environment(\.buttonHovered) private var lit
    @Environment(\.palette) private var palette
    let onNote: Bool

    /// 与那一行的日期同一种字、坐在行尾：不是浮在上面的一颗白钮。
    var body: some View {
        Image(.trash)
            .font(Typography.meta)
            .foregroundStyle(lit ? palette.failure : palette.ink3)
            .frame(width: ControlSize.target, height: ControlSize.target)
            .background { if onNote { Circle().fill(palette.note).brightness(PressFeedback.cardHover(palette)) } }
            .contentShape(.circle)
    }
}

/// 全 App 一套选中，不着靛青。
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
