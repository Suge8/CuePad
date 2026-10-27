#if os(macOS)
import CueStore
import SwiftUI

/// 点开编辑页的卡（墙上卡片、"更早"的行）的按压：样子同 `PressStyle(.card)`（`PressFeedback`，Mac 是按下即压暗、松开即复原），
/// 只是按下与否看这张卡的按下状态（`cardHeld`：鼠标按着——AppKit 分发按下事件时就记下，早于按钮识别——或已打开、编辑页还在准备），
/// 按钮自己识别出的按下兜底：打开后编辑页还在准备的那几帧保持按下，编辑页淡入时松开；松开没打开（拖走、取消）就复原。
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

/// 卡面：首图、标题、摘要、元信息（时间、发送目标、浮回、任务与置顶标记）。单独一个视图：悬停只改卡的外框，卡面不随之重算。
private struct CardFace: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(card.body)
        VStack(alignment: .leading, spacing: 8) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-8).padding(.bottom, 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                .padding(.top, 2)
        }
        .padding(16)
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
        .paper()
        .overlay { SelectedFrame() }
        .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering, !workspace.presses.isSelecting {
                DeleteCardButton(card: card.id).padding(10).transition(.opacity)
            }
        }
        .cardPresence(card.id, in: workspace)
        // 灵感要做就拖到上面任务纸的一行上，接进那条任务（`TaskOutline`）
        .onDrag { CardDragSession.shared.begin(.idea(card.id)) }
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

/// 悬停在墙上一张卡、"更早"一行时露出的删除：进回收站，提示里可撤销（`Workspace.trash`，与右键菜单、⌘⌫ 同一处）。
/// 批量选择时不出现（删除在底部的操作栏里）。
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

/// 删除钮的样子：指针停在钮上（`buttonHovered`）时垃圾桶变成出错色。
private struct DeleteGlyph: View {
    @Environment(\.buttonHovered) private var lit
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.trash)
            .font(Typography.meta.weight(.medium))
            .foregroundStyle(lit ? palette.failure : palette.ink2)
            .frame(width: 24, height: 24)
            .background(palette.paperLit, in: .circle)
            .overlay(Circle().strokeBorder(palette.hair))
            .shadow(color: palette.shadow, radius: 6, y: 2)
            .contentShape(.circle)
    }
}

/// 批量选择里选上的卡：一圈签名色的边，右上角一个对勾。
private struct SelectedFrame: View {
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.signature, lineWidth: 2)
                .overlay(alignment: .topTrailing) {
                    Image(.picked).font(.system(size: 18)).foregroundStyle(palette.onFill, palette.signature)
                        .padding(10)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

#endif
