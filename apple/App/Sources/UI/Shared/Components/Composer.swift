import CueStore
import CueText
import SwiftUI

/// 随手记、新会话与 Pi 会话回复框共用的输入框（iOS 与 Mac 同一份；文字区各用平台的文本视图，见 `ComposerField`；图片来源与带上的卡片的菜单、面板
/// 在 `Composer+iOS`、`Composer+macOS`）：一层玻璃，里面是（调用方放的）头部、带上的卡片、图片条、文字区，以及底下一整排工具：
/// 左"＋"（选卡片、相册、拍照）、调用方的小圆钮（会话回复框的模型与思考强度），右提交钮，"＋"与提交钮钉在左下、右下角。
/// 一直展开（`ComposerForm.open`，不变形）又有工具的，文字铺满整宽在上，底下一排是＋、工具与提交钮；其余的文字区一直在两颗圆钮中间、往上长，
/// 工具排（有就）在文字下面、两颗圆钮之间：变形时只有玻璃上沿与文字往上下挪，没有横着挪的东西——文字区是平台的文本视图，
/// 变形时它一下换到新位置，横着挪的"＋"会从字上滑过、挪着的提交钮被玻璃下沿裁掉。带上的卡片点一下看全文，能"展开编辑"成这次要发的文字。
/// 调用方给草稿、占位、接受的种类和提交钮，草稿怎么处理由它们决定；回复框另给键盘快捷键（`ReplyShortcut`）与空着时按 ↑ 调回的那一句（`recall`）。
struct Composer<Header: View, Tools: View, Send: View>: View {
    @Binding var draft: ComposerDraft
    let prompt: String
    let label: String
    let focus: FocusState<Bool>.Binding
    var accepts: ComposerKinds = [.images, .cards]
    /// 选卡片时排在前面的项目（回复框是会话所属的项目）。
    var cardsFrom: UUID?
    var form = ComposerForm.open
    /// 这张带上的卡片不能拿掉（发给 Agent 的输入框是为它打开的）。
    var keeps: UUID?
    /// 空着也能提交：提交钮的位置一直在、快捷键不要求有内容（新会话的第一句话可不填；会话回复框在 Agent 跑一轮时空着的钮是"停止"）。
    /// 输入框写着"可不填"的，都靠它——空草稿能不能提交只在这里定。
    var submitsEmpty = false
    /// 空着时钮位也露出钮（只是看的，不能提交）："对 Cue 说"发出后的发送中（话在路上）。
    var showsSendEmpty = false
    /// 收成一行时头部也留着（会话回复框：排队的话在这块玻璃的上部）；平时头部只在展开时出现。
    var keepsHeader = false
    /// 有工具排（`tools`：会话的模型与思考强度）。一直展开的有工具时才分两层（文字在上、＋工具提交钮一排在下），没有工具的照旧一排；
    /// 会收起的在聚焦时文字下面多一排。
    var tooled = false
    /// 这个会话此刻能用的斜杠命令：输入 "/" 时弹出面板（`PiSlashPalette`）；空表示不弹。
    var commands: [PiSlashCommand] = []
    var shortcuts: [ReplyShortcut: () -> Void] = [:]
    /// 空着时按 ↑ 放进来的话，存储格式（回复框：你在这个会话里说过的上一句，文字与图片）。
    var recall: String?
    @ViewBuilder let header: () -> Header
    /// 工具排里"＋"右边的小圆钮（会话回复框的模型与思考强度）：一直展开的形态里一直在，会收起的形态里只在聚焦时出现。
    @ViewBuilder let tools: () -> Tools
    @ViewBuilder let send: () -> Send
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 跟着焦点、带动画：UIKit 文字区拿到焦点时的那次更新不带动画，直接读焦点时展开会一帧跳到位
    @State private var focused = false
    @State private var source: ComposerSource?
    @State private var previewing: Outbox?
    /// 斜杠命令面板里高亮的那一行，与按过 Esc 收起面板时的那段文字（文字再变就又弹出）。
    @State private var highlighted = 0
    @State private var dismissedPalette: String?


    private var expanded: Bool { !shrunk && (form == .open || (focused && form.opensOnFocus) || !draft.isEmpty(accepting: [.images, .cards])) }
    /// 收成短胶囊：一行的形态再变窄、居中，点它照常聚焦展开。有草稿也收（胶囊里写"草稿：第一行"）：翻历史时整宽的两层太占地方。
    private var shrunk: Bool { form.isCapsule && !focused }
    private var showsTools: Bool { form == .open || focused }
    /// 收着的草稿：文字区藏起（还是同一个，焦点与输入法不断），换成一行预览。
    private var shrunkDraft: String? { shrunk ? draft.preview : nil }
    private static var compactWidth: CGFloat { 220 }
    private static var headerTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.quick.delay(0.12)), removal: .identity)
    }
    /// 玻璃上方允许浮出的高度（见 `field` 的裁切）。
    private static var overhang: CGFloat { 120 }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }
    private var sendVisible: Bool { !shrunk && (hasContent || submitsEmpty || showsSendEmpty) }

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
            draft.append(stored: recall, files: workspace.services.store.files)
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
        // 短胶囊 ↔ 全宽、聚焦时工具排出现是空间动画：无回弹弹簧，减弱动态效果时直接到终态。打字与清空（有没有草稿）时高度一帧到位：
        // 文字区是平台的文本视图，折行长高本来就是一帧到位，收回时也一样，占位字不悬在上一行；浮着的输入框上面的对话也同一帧跟
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: shrunk)
        .onChange(of: focus.wrappedValue, initial: true) { _, now in
            // 一直展开时焦点不改形状，不起动画：Mac 会话页打开即聚焦，白跑的一段动画每帧都要 AppKit 重算整窗的跟踪区
            if form == .open { focused = now } else { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { focused = now } }
        }
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
                ForEach(draft.attachments) { chip($0).padding([.horizontal, .top], ComposerMetrics.inset).transition(.opacity) }
            }
            if accepts.contains(.images), !draft.images.isEmpty {
                imageStrip.padding([.horizontal, .top], ComposerMetrics.inset).transition(.opacity)
            }
            if form == .open, tooled { layered } else { row }
        }
        // 提交钮只有一颗，浮在右下角留出的位置上：有没有内容都不改它的位置与输入框的宽
        .overlay(alignment: .bottomTrailing) { if !shrunk { sendSlot } }
        // 整块玻璃都是输入框：点在文字区以外（边距、两个圆钮之间的空处）也聚焦，不落空（文字区只占中间一条，
        // 外面原本什么都接不住，点下去玻璃动了一下却没聚焦，得再点一次）。文字区、＋ 与提交钮在它上面，照旧自己接
        .background {
            if !focused {
                Color.clear.contentShape(.rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
                    .onTapGesture { focus.wrappedValue = true }
                    .accessibilityHidden(true)
            }
        }
        // 收成短胶囊时居中；展开是同一块玻璃从中间向两边长到全宽
        .frame(maxWidth: shrunk ? Self.compactWidth : .infinity, alignment: .leading)
        // 里面的东西裁在玻璃里：变形时淡出中的提交钮、工具排随玻璃一起收，不留在玻璃外。上沿不裁（往上浮出的
        // "长按可马上说"、思考强度的读数要露在玻璃上方），所以裁的形状向上伸出去
        .mask { RoundedRectangle(cornerRadius: ComposerMetrics.radius, style: .continuous).padding(.top, -Self.overhang) }
        .rowContainer(.rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
        .glass(in: .rect(cornerRadius: ComposerMetrics.radius, style: .continuous), interactive: !expanded)
        .frame(maxWidth: .infinity)
    }

    /// 一直展开、有工具：文字铺满整宽在上，底下一排＋、工具与提交钮的位置。
    private var layered: some View {
        VStack(alignment: .leading, spacing: 0) {
            text.padding(.horizontal, 18).padding(.top, ComposerMetrics.textTop).padding(.bottom, ComposerMetrics.textBottomOpen)
            HStack(spacing: 0) {
                if !accepts.isEmpty { plus }
                tools()
                Spacer(minLength: 0)
                slotSpace
            }
        }
    }

    /// 其余：文字区（换形态时不重建，焦点与输入法组合都不断）一直在＋与提交钮之间，两颗圆钮底对齐、钉在角上。
    private var row: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if !accepts.isEmpty { plus }
            VStack(alignment: .leading, spacing: 0) {
                text
                    .padding(.leading, accepts.isEmpty ? 18 : 2).padding(.trailing, shrunk ? 18 : 2)
                    .padding(.vertical, ComposerMetrics.textTop)
                    .frame(minHeight: ComposerMetrics.slot)
                // 工具排与两颗圆钮同一条中线；没有工具时这里是空的，不占位
                if tooled, expanded, showsTools {
                    tools()
                        .frame(height: ComposerMetrics.slot - 2 * ComposerMetrics.inset)
                        .padding(.bottom, ComposerMetrics.inset)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                }
            }
            if !shrunk { slotSpace }
        }
    }

    private var text: some View {
        ComposerField(
            text: $draft.text, prompt: prompt, label: label, maxLines: expanded ? 6 : 1, ink: palette.ink, focus: focus, keys: handle,
            shortcut: shortcut)
            .focused(focus)
            // 收起时原文与"草稿：…"在同一个位置一换即成，不两层叠着交叉淡：同一行字在变形中只有一层
            .animation(nil) { $0.opacity(shrunkDraft == nil ? 1 : 0) }
            .overlay(alignment: .leading) {
                if let shrunkDraft {
                    Text("草稿：\(shrunkDraft)").font(Typography.reading).foregroundStyle(palette.ink2).lineLimit(1)
                        .allowsHitTesting(false)
                        .transition(.identity)
                }
            }
    }

    /// 提交钮的位置一直留着（收成短胶囊时除外）：有内容才放进来，输入框的宽度不随它变，文字不会因此重排——
    /// 宽度跟着钮进出变的话，动画的每一帧文字区（UITextView/NSTextView）都要重新排版，发出、送达、打第一个字各多一段主线程开销。
    private var slotSpace: some View { Color.clear.frame(width: ComposerMetrics.slot, height: ComposerMetrics.slot) }

    private var sendSlot: some View {
        ZStack {
            if sendVisible { send().transition(.scale(scale: 0.6).combined(with: .opacity)) }
        }
        .frame(width: ComposerMetrics.slot, height: ComposerMetrics.slot)
        // 只管钮自己进出：打第一个字时钮出现与一行变两层是同一次更新，挂在整块上的话"＋"的挪位也跟着它动画（减弱动态效果时也滑）
        .animation(Motion.quick, value: sendVisible)
    }

    private var plus: some View {
        let cards = accepts.contains(.cards) ? [ChoiceMenu.Choice(title: "选灵感或任务", image: .icon(.pickCards)) { source = .cards }] : []
        let images = accepts.contains(.images) ? ComposerSource.imageChoices.map { choice in
            ChoiceMenu.Choice(title: choice.title, image: .icon(choice.icon)) { source = choice.source }
        } : []
        return MenuButton(sections: [ChoiceMenu.Section(choices: cards + images)], press: .button, accessibilityLabel: "添加") {
            CircleGlyph(fill: palette.fill) { Image(.add).font(.body.weight(.semibold)).foregroundStyle(palette.ink) }
                .frame(width: ComposerMetrics.slot, height: ComposerMetrics.slot)
        }
        .fixedSize()
    }

    /// 带上的卡片或任务：标题、图片数，可移除；点一下看全文，长按（Mac 右键）出"展开编辑""不带了"（`AttachmentButton`）。
    private func chip(_ outbox: Outbox) -> some View {
        let card = CardText(outbox.content)
        let removable = outbox.card != keeps
        let shape = RoundedRectangle(cornerRadius: ComposerMetrics.radius - ComposerMetrics.inset, style: .continuous)
        let menu = removable ? [ChoiceMenu.Section(choices: [
            ChoiceMenu.Choice(title: "展开编辑", image: .icon(.expandEdit)) { expand(outbox) },
            ChoiceMenu.Choice(title: "不带了", image: .icon(.remove), destructive: true) { drop(outbox) },
        ])] : []
        return HStack(spacing: 0) {
            AttachmentButton(label: "带上：\(card.title.nonEmpty ?? "图片")", menu: menu, open: { previewing = outbox }) {
                HStack(spacing: 10) {
                    Image(.pickCards).foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title.nonEmpty ?? "图片").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        // 去处收不了图片时卡片里的图片不发（`ComposerDraft.accepting`），不写张数
                        if accepts.contains(.images), !card.images.isEmpty {
                            Text("\(card.images.count) 张图片").font(Typography.caption).foregroundStyle(palette.ink3)
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
                    .buttonStyle(.plain)
            }
        }
        .background(palette.fill, in: shape)
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    ZStack(alignment: .topTrailing) {
                        image.preview.resizable().scaledToFill()
                            .frame(width: PickedImage.previewSide, height: PickedImage.previewSide)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hair))
                        Button { draft.images.removeAll { $0.id == image.id } } label: {
                            Image(.clear).symbolRenderingMode(.palette)
                                .foregroundStyle(palette.onMedia, palette.mediaScrim).font(.body)
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

    /// 展开编辑：卡片的文字与图片放回输入框（`ComposerDraft.append`），不再作为整张卡带上，原卡片不动。
    private func expand(_ outbox: Outbox) {
        draft.append(stored: outbox.content, files: workspace.services.store.files)
        drop(outbox)
        previewing = nil
        focus.wrappedValue = true
    }
}

/// 输入框的尺寸：单行时高 `slot`（字行 + 上下各 `textTop`），圆角取一半成胶囊；圆钮一格 `slot`（`CircleGlyph` 的圆 + 四周的边距）、
/// 离边 `inset`，与外框同心。一直展开时文字区下面只留 `textBottomOpen`，再下面是一格高的那一排；会展开收起的工具排在文字下面，
/// 高是圆钮的圆（`slot - 2 * inset`），离底 `inset`，与两颗圆钮同一条中线。
enum ComposerMetrics {
    static let radius: CGFloat = 28
    static let inset: CGFloat = 8
    static let slot: CGFloat = 56
    static let textTop: CGFloat = 17
    static let textBottomOpen: CGFloat = 4
}

/// 文字区要多高（两端的 `ComposerField` 各持一份）：最高只露出 `limit`，所以只排开头够撑满上限的那一段，不排整篇——
/// 粘贴几百行进来后每敲一个字都整篇重排，一个字要两三百毫秒。开头一段排出的高度不会超过整篇的（后面的字只会多出行），
/// 够上限就是上限；不够再排长一倍，排到整篇为止。先排的字数按全角字估（全角字最宽，撑满同样的行数要的字最少）：
/// SwiftUI 每次排版还会拿宽度 0 来探，那时几个字就竖着撑满了，不能一上来就排上千个字；横排里有别的圆钮（Agent 跑一轮时的停止钮）时
/// 还会拿无穷宽来量它最宽能多宽，那时估不出字数，从最短的一段排起（无穷宽、极宽转整数会让 App 崩溃）。
/// 量过的按宽度各记一份（一次排版里会按几种宽度轮流问）；文字变了时，撑满过上限的那段开头没动（接着往后写）就还是上限，不再排。
struct ComposerHeight {
    private var fits: [Key: Fit] = [:]
    /// 文字第几版（`textChanged` 加一）：同一版里量过的直接用。
    private var version = 0

    private struct Key: Hashable { var width, em, limit: CGFloat }
    private struct Fit {
        var height: CGFloat
        /// 撑满上限的那段开头；没撑满是 nil。
        var filled: NSString?
        var version: Int
    }

    /// 文字变了（打字、外部写入）：只留这一版里问过、撑满过上限的，别的作废（动画里一帧一个宽度，不留着越攒越多）。
    mutating func textChanged() {
        fits = fits.filter { $0.value.version == version && $0.value.filled != nil }
        version += 1
    }

    /// `measure` 是平台的排版：按这个宽度排这段字有多高。
    mutating func height(of text: NSString, width: CGFloat, em: CGFloat, limit: CGFloat, measure: (String) -> CGFloat) -> CGFloat {
        let key = Key(width: width, em: em, limit: limit)
        if let fit = fits[key] {
            if fit.version == version { return fit.height }
            if let filled = fit.filled, text.hasPrefix(filled as String) {
                fits[key]?.version = version
                return limit
            }
        }
        let fit = Self.fit(text, width: width, em: em, limit: limit, measure: measure)
        fits[key] = Fit(height: fit.height, filled: fit.filled, version: version)
        return fit.height
    }

    private static func fit(
        _ text: NSString, width: CGFloat, em: CGFloat, limit: CGFloat, measure: (String) -> CGFloat
    ) -> (height: CGFloat, filled: NSString?) {
        let estimate = limit / em * width / em
        var length = estimate.isFinite ? max(minSpan, Int(min(estimate, CGFloat(text.length)))) : minSpan
        while length < text.length {
            let prefix = text.substring(to: text.rangeOfComposedCharacterSequence(at: length).location)
            if measure(prefix) >= limit { return (limit, prefix as NSString) }
            length *= 2
        }
        let height = measure(text as String)
        return height >= limit ? (limit, text.copy() as? NSString) : (height, nil)
    }

    private static let minSpan = 16
}

extension String {
    /// 文字区里的字整块拷成原生字符串。文字区的 `text`、`string` 桥接过来是包着可变 NSString 的外来字符串，
    /// 草稿的每个读者（预览、空不空、比较、存偏好）在它上面都逐字走慢路，几百行时每个字要多花几毫秒。
    init(native text: NSString) {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        self.init(decoding: units, as: UTF16.self)
    }
}

/// 输入框的形态，几时一行、几时两层只在这里定（一个输入框一个值，调用方按场景给）。
enum ComposerForm: Equatable {
    /// 一直是两层、工具排一直在：浮起的输入框（新会话、交给 Agent）、Mac 菜单栏面板、Mac 会话回复框。
    case open
    /// 空着又没聚焦时收成一行；有内容时两层，`opensOnFocus` 时聚焦也展开（Mac 底部输入栏；手机会话回复框：
    /// 有工具排时聚焦就展开，已结束的会话没有工具，聚焦了也保持一行，打了字再长）。
    case line(opensOnFocus: Bool)
    /// 没聚焦时收成短胶囊（＋ 与一行提示，有草稿写"草稿：第一行"），点它聚焦后同 `line`（手机会话页在看历史时）。
    case capsule(opensOnFocus: Bool)

    var opensOnFocus: Bool {
        switch self {
        case .open: true
        case .line(let opens), .capsule(let opens): opens
        }
    }

    var isCapsule: Bool { if case .capsule = self { true } else { false } }
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
