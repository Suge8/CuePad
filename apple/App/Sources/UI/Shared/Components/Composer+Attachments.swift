import CueEditor
import CueText
import SwiftUI

extension Composer {
    var plus: some View {
        let cards = accepts.contains(.cards) ? [ChoiceMenu.Choice(title: "选灵感或任务", image: .icon(.pickCards)) { source = .cards }] : []
        let files = accepts.contains(.files) ? ComposerSource.fileChoices.map { choice in
            ChoiceMenu.Choice(title: choice.title, image: .icon(choice.icon)) { source = choice.source }
        } : []
        return MenuButton(sections: [ChoiceMenu.Section(choices: cards + files)], press: .button, accessibilityLabel: "添加") {
            CircleGlyph(fill: palette.fill) { Image(.add).font(Glyph.control.weight(.semibold)).foregroundStyle(palette.ink) }
                .frame(width: ComposerMetrics.slot, height: buttonHeight)
        }
        .fixedSize()
    }

    func chip(_ outbox: Outbox) -> some View {
        let card = CardText(outbox.content), name = card.title.nonEmpty ?? String(localized: "附件")
        let attached = CueFormat.attachmentKeys(in: outbox.content).count
        let removable = outbox.card != keeps
        let shape = Radius.nested
        let menu = removable ? [ChoiceMenu.Section(choices: [
            ChoiceMenu.Choice(title: "展开编辑", image: .icon(.expandEdit)) { expand(outbox) },
            ChoiceMenu.Choice(title: "不带了", image: .icon(.remove), destructive: true) { drop(outbox) },
        ])] : []
        return HStack(spacing: 0) {
            AttachmentButton(label: "带上：\(name)", menu: menu, open: { previewing = outbox }) {
                HStack(spacing: Spacing.item) {
                    Image(.pickCards).foregroundStyle(palette.ink3)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(name).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        if accepts.contains(.files), attached > 0 {
                            Text("\(attached) 个附件").font(Typography.caption).foregroundStyle(palette.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, Spacing.group).frame(minHeight: 44)
                .contentShape(.rect)
            }
            if removable {
                Button("不带了", icon: .remove) { drop(outbox) }
                    .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                    .frame(width: 44, height: 44).contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
            }
        }
        .background(palette.fill, in: shape)
    }

    var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.item) {
                ForEach(draft.files) { file in
                    ZStack(alignment: .topTrailing) {
                        if file.isImage {
                            ImageTile(key: file.key, among: draft.files, group: "draft")
                        } else {
                            FileChip(key: file.key, name: file.name, height: Self.stripSide, among: draft.files, group: "draft").frame(maxWidth: 220)
                        }
                        Button { draft.files.removeAll { $0 == file } } label: {
                            Image(.clear).symbolRenderingMode(.palette)
                                .foregroundStyle(file.isImage ? palette.onMedia : palette.paper, file.isImage ? palette.mediaScrim : palette.ink2).font(Glyph.control)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(file.isImage ? "移除这张图片" : "移除这个文件")
                    }
                    .modifier(AttachmentPop())
                }
            }
        }
    }

    static var stripSide: CGFloat { 64 }

    /// 存的途中发出的话，附件随这句发出（`Workspace.importFiles`）。
    func add(_ incoming: [IncomingFile]) { workspace.importFiles(incoming, into: $draft) }

    func drop(_ outbox: Outbox) { draft.attachments.removeAll { $0.id == outbox.id } }

    func expand(_ outbox: Outbox) {
        draft.append(stored: outbox.content)
        drop(outbox)
        previewing = nil
        focus.wrappedValue = true
    }
}

private struct AttachmentPop: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(Motion.pop(reduceMotion: reduceMotion))
    }
}

/// 不接受卡片的（随手记）不挂，Mac 上也就不需要浮层宿主（菜单栏面板没有）。`on` 对一个输入框是定值，不会来回换结构。
struct CardPanels<Picker: View, Preview: View>: ViewModifier {
    let on: Bool
    let picking: Binding<Bool>
    let previewing: Binding<Outbox?>
    @ViewBuilder let picker: () -> Picker
    @ViewBuilder let preview: (Outbox) -> Preview

    func body(content: Content) -> some View {
        if on {
            content
                .panel(isPresented: picking, content: picker)
                .panel(item: previewing, content: preview)
        } else {
            content
        }
    }
}
