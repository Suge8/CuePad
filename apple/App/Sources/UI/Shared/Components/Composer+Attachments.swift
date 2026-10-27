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
            CircleGlyph(fill: palette.fill) { Image(.add).font(.body.weight(.semibold)).foregroundStyle(palette.ink) }
                .frame(width: ComposerMetrics.slot, height: buttonHeight)
        }
        .fixedSize()
    }

    /// 带上的卡片或任务：标题、附件数（图片与文件），可移除；点一下看全文，长按（Mac 右键）出"展开编辑""不带了"（`AttachmentButton`）。
    func chip(_ outbox: Outbox) -> some View {
        let card = CardText(outbox.content), name = card.title.nonEmpty ?? String(localized: "附件")
        let attached = CueFormat.attachmentKeys(in: outbox.content).count
        let removable = outbox.card != keeps
        let shape = RoundedRectangle(cornerRadius: ComposerMetrics.radius - ComposerMetrics.inset, style: .continuous)
        let menu = removable ? [ChoiceMenu.Section(choices: [
            ChoiceMenu.Choice(title: "展开编辑", image: .icon(.expandEdit)) { expand(outbox) },
            ChoiceMenu.Choice(title: "不带了", image: .icon(.remove), destructive: true) { drop(outbox) },
        ])] : []
        return HStack(spacing: 0) {
            AttachmentButton(label: "带上：\(name)", menu: menu, open: { previewing = outbox }) {
                HStack(spacing: 10) {
                    Image(.pickCards).foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        // 去处收不了附件时卡片里的附件不发（`ComposerDraft.accepting`），不写个数
                        if accepts.contains(.files), attached > 0 {
                            Text("\(attached) 个附件").font(Typography.caption).foregroundStyle(palette.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 12).frame(minHeight: 44)
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

    /// 附件条：图片是方块缩略图，别的文件是文件牌（`FileChip`），各带一颗移除；点一个快速查看。
    var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.files) { file in
                    ZStack(alignment: .topTrailing) {
                        if file.isImage {
                            ImageTile(key: file.key)
                        } else {
                            FileChip(key: file.key, name: file.name, height: Self.stripSide).frame(maxWidth: 220)
                        }
                        Button { draft.files.removeAll { $0 == file } } label: {
                            Image(.clear).symbolRenderingMode(.palette)
                                .foregroundStyle(palette.onMedia, palette.mediaScrim).font(.body)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(file.isImage ? "移除这张图片" : "移除这个文件")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    static var stripSide: CGFloat { 64 }

    /// 存进附件目录（后台）再接进附件条；已带着的不重复。选来的文件有安全作用域的，存好才放开访问。
    func add(_ incoming: [IncomingFile]) {
        let files = workspace.services.store.files
        let scoped = incoming.compactMap { if case .file(let url) = $0, url.startAccessingSecurityScopedResource() { url } else { nil } }
        Task {
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            for item in incoming {
                do {
                    let file = try await DraftFile.store(item, in: files)
                    if !draft.files.contains(file) { draft.files.append(file) }
                } catch {
                    workspace.fail(error)
                }
            }
        }
    }

    func drop(_ outbox: Outbox) { draft.attachments.removeAll { $0.id == outbox.id } }

    /// 展开编辑：卡片的文字与附件放回输入框（`ComposerDraft.append`），不再作为整张卡带上，原卡片不动。
    func expand(_ outbox: Outbox) {
        draft.append(stored: outbox.content)
        drop(outbox)
        previewing = nil
        focus.wrappedValue = true
    }
}

/// 带卡片的输入框才挂的两个弹层：挑灵感或任务、看带上的那张卡。不接受卡片的（随手记）不挂，Mac 上也就不需要浮层宿主
/// （菜单栏面板没有）。`on` 对一个输入框是定值，不会来回换结构。
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
