import CueStore
import SwiftUI

/// 随手记、新会话与 Pi 会话回复框共用的输入框（iOS 与 Mac 同一份；文字区各用平台的文本视图，见 `ComposerField`；图片来源与带上的卡片的菜单、面板
/// 在 `Composer+iOS`、`Composer+macOS`）：一层玻璃，里面是（调用方放的）头部、带上的卡片、图片条、文字区，以及底下一整排工具：
/// 左"＋"（选卡片、相册、拍照；粘贴的图片也进图片条）、调用方的小圆钮（会话回复框的模型与思考强度），右提交钮，"＋"与提交钮钉在左下、右下角。
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
    /// 收成一行时头部也留着（会话回复框：批注在这块玻璃的上部）；平时头部只在展开时出现。
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
    @Environment(Workspace.self) var workspace
    @Environment(\.palette) var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 跟着焦点、带动画：UIKit 文字区拿到焦点时的那次更新不带动画，直接读焦点时展开会一帧跳到位
    @State private var focused = false
    @State var source: ComposerSource?
    @State var previewing: Outbox?
    /// 斜杠命令面板里高亮的那一行，与按过 Esc 收起面板时的那段文字（文字再变就又弹出）。
    @State private var highlighted = 0
    @State private var dismissedPalette: String?


    private var expanded: Bool { !shrunk && (form == .open || (focused && form.opensOnFocus) || !draft.isEmpty(accepting: [.images, .cards])) }
    /// 收成短胶囊：一行的形态再变窄、居中，点它照常聚焦展开。有草稿也收（胶囊里写"草稿：第一行"）：翻历史时整宽的两层太占地方。
    private var shrunk: Bool { form.isCapsule && !focused }
    private var showsTools: Bool { form == .open || focused }
    /// 圆钮那一格的高：露出工具排时与工具排同一条中线（`slot`），否则与最后一行字同一条中线（字号大了跟着高）。
    var buttonHeight: CGFloat {
        tooled && expanded && showsTools ? ComposerMetrics.slot : ComposerMetrics.lineSlot(line: ComposerField.lineHeight(typeSize))
    }
    /// 收着的草稿：文字区藏起（还是同一个，焦点与输入法不断），换成一行预览。
    private var shrunkDraft: String? { shrunk ? draft.preview : nil }
    private static var compactWidth: CGFloat { 220 }
    private static var headerTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(HandOff.quick.delay(0.12)), removal: .identity)
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
        key == .send && !hasContent && !submitsEmpty ? nil : shortcuts[key]
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
        .animation(HandOff.quick, value: paletteCommands.isEmpty)
        .onChange(of: draft.text) { highlighted = 0 }
        .animation(HandOff.quick, value: draft.attachments.map(\.id))
        .animation(HandOff.quick, value: draft.images.map(\.id))
        .modifier(ImageSources(source: $source, images: $draft.images))
        .modifier(CardPanels(on: accepts.contains(.cards), picking: $source.isOn(.cards), previewing: $previewing) {
            CardPicker(project: cardsFrom) { draft.attach($0) }
        } preview: { outbox in
            AttachmentSheet(outbox: outbox) { expand(outbox) }
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
        // 思考强度的读数要露在玻璃上方），所以裁的形状向上伸出去
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
                    .frame(minHeight: buttonHeight)
                // 工具排与两颗圆钮同一条中线；没有工具时这里是空的，不占位
                if tooled, expanded, showsTools {
                    tools()
                        .frame(minHeight: ComposerMetrics.slot - 2 * ComposerMetrics.inset)
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
            shortcut: shortcut, images: accepts.contains(.images) ? { draft.images += $0.map(PickedImage.init(data:)) } : nil)
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
    private var slotSpace: some View { Color.clear.frame(width: ComposerMetrics.slot, height: buttonHeight) }

    private var sendSlot: some View {
        ZStack {
            if sendVisible { send().transition(.scale(scale: 0.6).combined(with: .opacity)) }
        }
        .frame(width: ComposerMetrics.slot, height: buttonHeight)
        // 只管钮自己进出：打第一个字时钮出现与一行变两层是同一次更新，挂在整块上的话"＋"的挪位也跟着它动画（减弱动态效果时也滑）
        .animation(HandOff.quick, value: sendVisible)
    }
}
