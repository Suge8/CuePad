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

/// 卡面：首图、标题、摘要、元信息（时间、发送目标、浮回、任务与资料标记）。单独一个视图：悬停只改卡的外框，卡面不随之重算。
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

/// 墙上的一张卡。
struct CardTile: View {
    /// 卡片的圆角。
    static let radius: CGFloat = 16

    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
        CardFace(card: card, lastTarget: lastTarget, floated: floated)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: Self.radius, lifted: hovering)
        .overlay { SelectedFrame(radius: Self.radius) }
        .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering, !workspace.presses.isSelecting {
                HStack(spacing: 6) {
                    DeleteCardButton(card: card.id)
                    MakeTaskButton(card: card.id)
                }
                .padding(10).transition(.opacity)
            }
        }
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .onAppear {
            guard DebugHooks.hovers(card.body) else { return }
            hovering = true
            workspace.presses.hover(card.id, inside: true)
        }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card, selectable: true) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "设为任务", makeTask)
    }

    private func makeTask() {
        let id = card.id
        workspace.attempt { try await workspace.setTodo(id, true) }
    }

    private func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

/// 悬停在墙上一张卡时右下角露出的"设为任务"：灵感变成任务的那一下（第一行做标题，其余是它的正文，`CueStore.setTodo`），
/// 卡离开墙、出现在上面的任务里，行尾就是"开始"。圈是任务圈的样子，告诉你它会变成什么；批量选择时不出现（点按是选择）。
private struct MakeTaskButton: View {
    let card: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
            Button {
                let id = card
                workspace.attempt { try await workspace.setTodo(id, true) }
            } label: {
                HStack(spacing: 5) {
                    Circle().strokeBorder(hovering ? palette.onFill : palette.ink2, lineWidth: 1.3).frame(width: 11, height: 11)
                    Text("设为任务").fontWeight(.medium)
                }
                .font(Typography.meta)
                .foregroundStyle(hovering ? palette.onFill : palette.ink)
                .padding(.horizontal, 9).frame(height: 24)
                .background(hovering ? palette.signatureFill : palette.paperLit, in: .capsule)
                .overlay(Capsule().strokeBorder(palette.hair).opacity(hovering ? 0 : 1))
                .shadow(color: palette.shadow, radius: 6, y: 2)
                .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .help("设为任务：第一行做任务名，其余成为交给 Agent 的话")
    }
}

/// 悬停在墙上一张卡、"更早"一行时露出的删除：进回收站，提示里可撤销（`Workspace.trash`，与右键菜单、⌘⌫ 同一处）。
/// 批量选择时不出现（删除在底部的操作栏里）。
struct DeleteCardButton: View {
    let card: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button {
            let id = card
            workspace.attempt { try await workspace.trash(id) }
        } label: {
            Image(systemName: "trash")
                .font(Typography.meta.weight(.medium))
                .foregroundStyle(hovering ? palette.failure : palette.ink2)
                .frame(width: 24, height: 24)
                .background(palette.paperLit, in: .circle)
                .overlay(Circle().strokeBorder(palette.hair))
                .shadow(color: palette.shadow, radius: 6, y: 2)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("删除（⌘⌫），可撤销")
        .accessibilityLabel("删除")
    }
}

/// 批量选择里选上的卡：一圈签名色的边，右上角一个对勾。
private struct SelectedFrame: View {
    let radius: CGFloat
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.signature, lineWidth: 2)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(palette.onFill, palette.signature)
                        .padding(10)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

#endif
