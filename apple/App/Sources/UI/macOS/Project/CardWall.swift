#if os(macOS)
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

struct IdeaTile: View {
    let entry: CardEntry
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        let card = entry.card
        Button(action: open) {
            IdeaTileFace(entry: entry, floated: floated)
                .modifier(SelectedCard())
                .note(lifted: hovering)
                .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering, !workspace.presses.isSelecting {
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
        let card = entry.card
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

struct DeleteCardButton: View {
    let card: UUID
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

    var body: some View {
        Image(.trash)
            .font(Typography.meta)
            .foregroundStyle(lit ? palette.failure : palette.ink3)
            .frame(width: ControlSize.target, height: ControlSize.target)
            .background { if onNote { Circle().fill(palette.note).brightness(PressFeedback.cardHover(palette)) } }
            .contentShape(.circle)
    }
}

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

struct PickedMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.picked).foregroundStyle(palette.paper, palette.ink).allowsHitTesting(false)
    }
}

#endif
