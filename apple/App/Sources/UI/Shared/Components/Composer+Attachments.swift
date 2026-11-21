import CueEditor
import CueText
import SwiftUI

extension Composer {
    /// "＋"，或调用方换上的那一颗（`lead`）：同一颗钮，换的只是字形、底与点了做什么，换时字形原地替换、底渐变。
    var plus: some View {
        let cards = accepts.contains(.cards) ? [ChoiceMenu.Choice(title: "灵感或任务", image: .icon(.pickCards)) { source = .cards }] : []
        let files = accepts.contains(.files) ? ComposerSource.fileChoices.map { choice in
            ChoiceMenu.Choice(title: choice.title, image: .icon(choice.icon)) { source = choice.source }
        } : []
        return MenuButton(sections: lead == nil ? [ChoiceMenu.Section(choices: cards + files)] : [], primary: lead?.act, press: .button,
                          accessibilityLabel: lead?.label ?? "添加") {
            CircleGlyph(fill: lead?.on == true ? palette.selection : palette.fill) {
                Image(lead?.icon ?? .add).font(Glyph.control.weight(.semibold))
                    .foregroundStyle(lead?.enabled == false ? palette.ink3 : palette.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(Motion.fade, value: lead)
        }
        .disabled(lead?.enabled == false)
        .fixedSize()
        // 格子撑在钮外面：撑在标签里时悬停的底是整格那么大
        .frame(width: ComposerMetrics.slot, height: buttonHeight)
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
        // 整条是一颗钮（点开看全文），悬停的底铺满整条；拿掉的那颗叠在右端，自己另有一圈悬停的底。
        // 否决过：左右并排两颗——悬停的底只盖到左边那颗，右端空着一截；拿掉的那颗的点按区写在钮外面，实际只有图标那么大，几乎点不到。
        return AttachmentButton(label: "带上：\(name)", menu: menu, open: { previewing = outbox }) {
            HStack(spacing: Spacing.item) {
                Image(.pickCards).foregroundStyle(palette.ink3)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(name).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                    if accepts.contains(.files), attached > 0 {
                        Text("\(attached) 个附件").font(Typography.caption).foregroundStyle(palette.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, removable ? Spacing.group : Spacing.tight).padding(.trailing, removable ? Self.chipHeight : 0)
            .frame(minHeight: removable ? Self.chipHeight : nil)
            .contentShape(.rect)
        }
        .overlay(alignment: .trailing) {
            if removable {
                Button { drop(outbox) } label: {
                    Label("不带了", icon: .remove).labelStyle(.iconOnly).foregroundStyle(palette.ink2)
                        .frame(width: ComposerMetrics.glyphTarget, height: ComposerMetrics.glyphTarget).contentShape(.rect)
                }
                .buttonStyle(PressStyle(.button))
                .padding(.trailing, (Self.chipHeight - ComposerMetrics.glyphTarget) / 2)
            }
        }
        // 交出去的那件任务本身（去不掉的那条）是这块面板的标题，不铺底：面板已经是一张卡。带上的别的才是一块块能拿掉的东西
        .background(removable ? palette.fill : .clear, in: shape)
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
    /// 带上的那一条的高：手指点得准的一行
    static var chipHeight: CGFloat { 44 }

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
