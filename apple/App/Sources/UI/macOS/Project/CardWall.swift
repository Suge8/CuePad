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
        // 灵感要做就拖到上面任务纸的一行上接进那条任务（`TaskOutline`），或拖到纸底"添加任务"上照它新建一条（`newTaskDrop`）
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

/// 删除钮的样子：看得见的圆是 `inline` 那一档（浮在卡角、行尾，不压字），点得到的是 `ControlSize.target` 见方；
/// 指针停在钮上（`buttonHovered`）时垃圾桶变成出错色。
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

/// 批量选择里选上的卡：纸上铺一层选中底，右上角一个墨色对勾（全 App 一套选中，docs/ui.md「选中」，不着靛青）。
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

/// 批量选择里选上的记号：墨色圆里一个纸色对勾（深色下墨是浅的，勾跟着取纸色才看得见）。墙上的卡与"更早"的行同一个。
struct PickedMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.picked).foregroundStyle(palette.paper, palette.ink).allowsHitTesting(false)
    }
}

#endif
