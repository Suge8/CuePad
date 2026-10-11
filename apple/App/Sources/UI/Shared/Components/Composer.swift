import CueStore
import CueText
import SwiftUI

extension EnvironmentValues {
    /// 输入框玻璃的着色：回复框贴在对话下面、对话照样滚到它后面，用 `legible`；浮起的输入框（随手记、新会话、交给 Agent）
    /// 压在整页列表上、整块都是要读的字，由 `FloatingInput` 给 `solid`，工具那一排背后也不透出列表的字块。
    @Entry var composerInk: GlassInk = .legible
}

/// 随手记、新会话与 Pi 会话回复框共用的输入框（iOS 与 Mac 同一份；文字区各用平台的文本视图，见 `ComposerField`；图片来源与带上的卡片的菜单、面板
/// 在 `Composer+iOS`、`Composer+macOS`）：一层玻璃，里面是（调用方放的）头部、带上的卡片、图片条、文字区，以及底下一整排工具：
/// 左"＋"（选卡片、相册、拍照）、调用方的小圆钮（会话回复框的模型与思考强度，只在聚焦时有），右提交钮。空着又没聚焦时收成一行
/// （提交钮不占位）；聚焦或有内容时展开成两层，＋ 从文字区左边落到工具排左端，同一块玻璃连续变形。带上的卡片点一下看全文，能"展开编辑"成这次要发的文字。
/// 调用方给草稿、占位、接受的种类和提交钮，草稿怎么处理由它们决定；回复框另给键盘快捷键（`ReplyShortcut`）与空着时按 ↑ 调回的那一句（`recall`）。
struct Composer<Header: View, Tools: View, Send: View>: View {
    @Binding var draft: ComposerDraft
    let prompt: String
    let label: String
    let focus: FocusState<Bool>.Binding
    var accepts: ComposerKinds = [.images, .cards]
    /// 选卡片时排在前面的项目（回复框是会话所属的项目）。
    var cardsFrom: UUID?
    /// 一直展开（浮起的随手记）。
    var pinnedOpen = false
    /// 没聚焦、没内容时收成短胶囊（＋ 与一行提示），点它照常聚焦展开（会话页在看历史时）。
    var compact = false
    /// 这张带上的卡片不能拿掉（交给 Agent 的输入框是为它打开的）。
    var keeps: UUID?
    /// 空着也能提交：提交钮的位置一直在、快捷键不要求有内容（新会话的第一句话可不填；会话回复框在 Agent 跑一轮时空着的钮是"停止"）。
    /// 输入框写着"可不填"的，都靠它——空草稿能不能提交只在这里定。
    var submitsEmpty = false
    /// 聚焦就展开成两层。会话回复框只在有工具排（模型、思考强度）时这样：已结束的会话没有工具，聚焦了也保持一行，打了字再长。
    var expandsOnFocus = true
    /// 收成一行时头部也留着（会话回复框：排队的话在这块玻璃的上部）；平时头部只在展开时出现。
    var keepsHeader = false
    /// 这个会话此刻能用的斜杠命令：输入 "/" 时弹出面板（`PiSlashPalette`）；空表示不弹。
    var commands: [PiSlashCommand] = []
    var shortcuts: [ReplyShortcut: () -> Void] = [:]
    /// 空着时按 ↑ 放进来的话（回复框：你在这个会话里说过的上一句）。
    var recall: String?
    @ViewBuilder let header: () -> Header
    /// 工具排里"＋"右边的小圆钮（会话回复框的模型与思考强度），只在聚焦时出现。
    @ViewBuilder let tools: () -> Tools
    @ViewBuilder let send: () -> Send
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.composerInk) private var composerInk
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 跟着焦点、带动画：UIKit 文字区拿到焦点时的那次更新不带动画，直接读焦点时展开会一帧跳到位
    @State private var focused = false
    @State private var appeared = false
    @State private var source: ComposerSource?
    @State private var previewing: Outbox?
    /// 斜杠命令面板里高亮的那一行，与按过 Esc 收起面板时的那段文字（文字再变就又弹出）。
    @State private var highlighted = 0
    @State private var dismissedPalette: String?
    /// "＋"在一行与两层之间挪位时是同一颗（连续移动）。
    @Namespace private var layout

    /// 单行时输入框高 50（字行 + 上下各 14），圆角取一半成胶囊；圆钮一格 50（36 的圆 + 四周的点按区与边距）、离边 8，与外框同心。
    private static var radius: CGFloat { 25 }
    private static var inset: CGFloat { 8 }
    private static var slot: CGFloat { 50 }

    private var expanded: Bool { !shrunk && (pinnedOpen || (focused && expandsOnFocus) || !draft.isEmpty(accepting: [.images, .cards])) }
    /// 收成短胶囊：一行的形态再变窄、居中，点它照常聚焦展开。有草稿也收（胶囊里写"草稿：第一行"）：翻历史时整宽的两层太占地方。
    private var shrunk: Bool { compact && !focused && !pinnedOpen && !submitsEmpty }
    /// 收着的草稿：文字区藏起（还是同一个，焦点与输入法不断），换成一行预览。
    private var shrunkDraft: String? { shrunk ? draft.preview : nil }
    private static var compactWidth: CGFloat { 220 }
    private static var headerTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.quick.delay(0.12)), removal: .identity)
    }
    /// 玻璃上方允许浮出的高度（见 `field` 的裁切）。
    private static var overhang: CGFloat { 120 }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }
    private var sendVisible: Bool { !shrunk && (hasContent || submitsEmpty) }

    private var paletteCommands: [PiSlashCommand] {
        guard expanded, dismissedPalette != draft.text else { return [] }
        return PiSlash.matches(draft.text, in: commands) ?? []
    }

    /// 此刻能用的快捷键：发送的两种要有内容。
    private func shortcut(_ key: ReplyShortcut) -> (() -> Void)? {
        [.send, .sendHeld].contains(key) && !hasContent && !submitsEmpty ? nil : shortcuts[key]
    }

    /// 文字区交来的按键：面板打开时归面板；空着时 ↑ 调回 `recall`。返回是否已处理（没处理的照常输入）。
    private func handle(_ key: ComposerKey) -> Bool {
        let list = paletteCommands
        guard !list.isEmpty else {
            guard key == .up, let recall, draft.isEmpty(accepting: [.images, .cards]) else { return false }
            draft.text = recall
            return true
        }
        let current = min(highlighted, list.count - 1)
        switch key {
        case .up: highlighted = (current + list.count - 1) % list.count
        case .down: highlighted = (current + 1) % list.count
        case .accept: pick(list[current])
        case .dismiss: dismissedPalette = draft.text
        }
        return true
    }

    private func pick(_ command: PiSlashCommand) {
        draft.text = PiSlash.insertion(for: command)
        focus.wrappedValue = true
    }

    var body: some View {
        field
        // 变形（一行 ↔ 两层、短胶囊 ↔ 全宽、工具排的小圆钮出现）是空间动画：无回弹弹簧，减弱动态效果时退为短淡入淡出
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: shrunk)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        .onChange(of: focus.wrappedValue, initial: true) { _, now in
            // 出现的头几百毫秒里到位的焦点（Mac 会话页打开即聚焦）直接是展开的样子：逐帧长高要把 AppKit 的跟踪区每帧重算一遍
            if appeared { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { focused = now } } else { focused = now }
        }
        .task {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            appeared = true
        }
        .animation(Motion.quick, value: sendVisible)
        .animation(Motion.quick, value: paletteCommands.isEmpty)
        .onChange(of: draft.text) { highlighted = 0 }
        .animation(Motion.quick, value: draft.attachments.map(\.id))
        .animation(Motion.quick, value: draft.images.map(\.id))
        .modifier(ImageSources(source: $source, images: $draft.images))
        .modifier(CardPanels(on: accepts.contains(.cards), picking: $source.isOn(.cards), previewing: $previewing) {
            CardPicker(project: cardsFrom) { draft.attach($0) }
        } preview: { outbox in
            AttachmentSheet(outbox: outbox, expand: { expand(outbox) })
        })
        .task { await DebugHooks.presetComposer($draft, source: $source, store: workspace.services.store) }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部随玻璃变形进出：收起时立刻离开（淡出中的它会叠在收短的那行字上），展开时等文字区让开位置再淡入
            if !shrunk, expanded || keepsHeader { header().transition(Self.headerTransition) }
            if !paletteCommands.isEmpty {
                PiSlashPalette(commands: paletteCommands, highlighted: min(highlighted, paletteCommands.count - 1), pick: pick)
                    .transition(.opacity)
                Divider().padding(.horizontal, 12)
            }
            if accepts.contains(.cards) {
                ForEach(draft.attachments) { chip($0).padding([.horizontal, .top], Self.inset).transition(.opacity) }
            }
            if accepts.contains(.images), !draft.images.isEmpty {
                imageStrip.padding([.horizontal, .top], Self.inset).transition(.opacity)
            }
            // 文字区一直是这一个（换形态时不重建，焦点与输入法组合都不断）；一行时"＋"在它左边
            HStack(alignment: .bottom, spacing: 0) {
                if !expanded, !accepts.isEmpty { plus }
                ComposerField(
                    text: $draft.text, prompt: prompt, label: label, maxLines: expanded ? 6 : 1, ink: palette.ink, focus: focus, keys: handle,
                    shortcut: shortcut)
                    .focused(focus)
                    // 收起时原文与"草稿：…"在同一个位置一换即成，不两层叠着交叉淡：同一行字在变形中只有一层
                    .animation(nil) { $0.opacity(shrunkDraft == nil ? 1 : 0) }
                    .overlay(alignment: .leading) {
                        if let shrunkDraft {
                            Text("草稿：\(shrunkDraft)").font(Typography.body).foregroundStyle(palette.ink2).lineLimit(1)
                                .allowsHitTesting(false)
                                .transition(.identity)
                        }
                    }
                    .padding(.leading, !expanded && !accepts.isEmpty ? 2 : 18).padding(.trailing, !expanded && sendVisible ? 2 : 18)
                    .padding(.top, 14).padding(.bottom, expanded ? 4 : 14)
                    .frame(minHeight: expanded ? nil : Self.slot)
                if !expanded, sendVisible { sendSlot }
            }
            if expanded {
                HStack(spacing: 0) {
                    if !accepts.isEmpty { plus }
                    if focused { tools().transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity)) }
                    Spacer(minLength: 0)
                    sendSlot
                }
                .transition(.opacity)
            }
        }
        // 整块玻璃都是输入框：点在文字区以外（边距、两个圆钮之间的空处）也聚焦，不落空（文字区只占中间一条，
        // 外面原本什么都接不住，点下去玻璃动了一下却没聚焦，得再点一次）。文字区、＋ 与提交钮在它上面，照旧自己接
        .background {
            if !focused {
                Color.clear.contentShape(.rect(cornerRadius: Self.radius, style: .continuous))
                    .onTapGesture { focus.wrappedValue = true }
                    .accessibilityHidden(true)
            }
        }
        // 收成短胶囊时居中；展开是同一块玻璃从中间向两边长到全宽
        .frame(maxWidth: shrunk ? Self.compactWidth : .infinity, alignment: .leading)
        // 里面的东西裁在玻璃里：变形时淡出中的提交钮、工具排随玻璃一起收，不留在玻璃外。上沿不裁（往上浮出的
        // "长按可马上说"、思考强度的读数要露在玻璃上方），所以裁的形状向上伸出去
        .mask { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).padding(.top, -Self.overhang) }
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), interactive: !expanded, ink: composerInk)
        .frame(maxWidth: .infinity)
    }

    /// 提交钮的位置一直留着：有内容才放进来，输入框的宽度不随它变，文字不会因此重排。
    private var sendSlot: some View {
        ZStack {
            if sendVisible { send().transition(.scale(scale: 0.6).combined(with: .opacity)) }
        }
        .frame(width: Self.slot, height: Self.slot)
    }

    private var plus: some View {
        Menu {
            if accepts.contains(.cards) { Button("选灵感或任务", systemImage: "rectangle.on.rectangle") { source = .cards } }
            if accepts.contains(.images) {
                ForEach(ComposerSource.imageChoices, id: \.source) { choice in
                    Button(choice.title, systemImage: choice.symbol) { source = choice.source }
                }
            }
        } label: {
            CircleGlyph(fill: palette.fill) { Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(palette.ink) }
                .frame(width: Self.slot, height: Self.slot)
                .matchedGeometryEffect(id: "plus", in: layout)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("添加")
    }

    /// 带上的卡片或任务：标题、图片数，可移除；点一下看全文，长按是预览与"展开编辑"。
    private func chip(_ outbox: Outbox) -> some View {
        let card = CardText(outbox.content)
        let removable = outbox.card != keeps
        let shape = RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
        return HStack(spacing: 0) {
            Button { previewing = outbox } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title.nonEmpty ?? "图片").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        if !card.images.isEmpty {
                            Text("\(card.images.count) 张图片").font(Typography.caption).foregroundStyle(palette.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 12).frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("带上：\(card.title.nonEmpty ?? "图片")")
            .accessibilityHint("看全文")
            if removable {
                Button("不带了", systemImage: "xmark") { drop(outbox) }
                    .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                    .frame(width: 44, height: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
        }
        .background(palette.fill, in: shape)
        .attachmentContextMenu(outbox, shape: shape) {
            if removable {
                Button("展开编辑", systemImage: "text.cursor") { expand(outbox) }
                Button("不带了", systemImage: "xmark", role: .destructive) { drop(outbox) }
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    ZStack(alignment: .topTrailing) {
                        image.preview.resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hair))
                        Button { draft.images.removeAll { $0.id == image.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55)).font(.body)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除这张图片")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    private func drop(_ outbox: Outbox) { draft.attachments.removeAll { $0.id == outbox.id } }

    /// 展开编辑：卡片的文字放进输入框（接在已写的字前面）、图片放进图片条，不再作为整张卡带上，原卡片不动。
    private func expand(_ outbox: Outbox) {
        let text = CueFormat.parse(outbox.content).map { token in
            switch token {
            case .text(let text): text
            case .split: "---"
            case .image: ""
            }
        }
        .joined()
        .replacing(/\n{3,}/, with: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let images = CardText(outbox.content).images.compactMap { hash in
            workspace.services.store.files.fileURL(for: hash).flatMap { try? Data(contentsOf: $0) }.map(PickedImage.init(data:))
        }
        draft.text = [text, draft.text].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        draft.images = images + draft.images
        drop(outbox)
        previewing = nil
        focus.wrappedValue = true
    }
}

/// 带卡片的输入框才挂的两个弹层：挑灵感或任务、看带上的那张卡。不接受卡片的（随手记）不挂，Mac 上也就不需要浮层宿主
/// （菜单栏面板没有）。`on` 对一个输入框是定值，不会来回换结构。
private struct CardPanels<Picker: View, Preview: View>: ViewModifier {
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
