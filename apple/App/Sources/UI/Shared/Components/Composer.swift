import CueStore
import CueText
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

/// 带上的一张卡片或任务（输入框里的，或 iOS 交给 Agent 时浮起的那一份）。
struct Outbox: Identifiable {
    let id = UUID()
    var content: String
    var card: UUID?
    /// 卡片所在项目：选会话时它的会话排在前面。
    var project: UUID?
}

/// 输入框里的东西：文字、图片、带上的灵感或任务（可带几张，按带上的顺序；第一张是这次关联的那条——交给 Agent 时是那条提示词）。存成卡片（随手记）、发给 Pi（回复）、开场的话（新会话）都是它，
/// 去处只决定怎么处理这份草稿。
struct ComposerDraft {
    var text = ""
    var images: [PickedImage] = []
    var attachments: [Outbox] = []

    /// 带的内容里有没有图片：自己选的，或带上的卡片里的。
    var hasImages: Bool { !images.isEmpty || attachments.contains { !CardText($0.content).images.isEmpty } }

    /// "＋ 选灵感"带上一张（作为这次消息的附件，卡片本身不动）；已带着的不重复。
    mutating func attach(_ card: Card) {
        guard !attachments.contains(where: { $0.card == card.id }) else { return }
        attachments.append(Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID))
    }

    /// 按去处接受的种类，有没有可发的东西（不接受的种类不算）。
    func isEmpty(accepting kinds: ComposerKinds) -> Bool {
        text.allSatisfy(\.isWhitespace) && (!kinds.contains(.images) || images.isEmpty) && (!kinds.contains(.cards) || attachments.isEmpty)
    }

    /// 存储格式正文：图片文件在这里写入图片库。
    func stored(in files: AttachmentFiles) throws -> String {
        StoredBody.make(attachments: attachments.map(\.content), text: text, imageHashes: try images.map { try files.store($0.data) })
    }
}

extension AppServices {
    /// 把草稿发给一个 Pi 会话（写投送请求）：关联 `card`（交给 Agent 时是为它打开的那条，不随附件增删），没给时是带上的第一张。
    @discardableResult
    func requestMacDelivery(
        _ draft: ComposerDraft, to session: PiSessionState, mode: DeliveryMode, card: UUID? = nil
    ) async throws -> DeliveryRequest {
        try await requestMacDelivery(draft.stored(in: store.files), to: session, mode: mode, card: card ?? draft.attachments.first?.card)
    }
}

/// 一个去处接受草稿里的哪几种东西。
struct ComposerKinds: OptionSet {
    let rawValue: Int
    static let images = ComposerKinds(rawValue: 1)
    static let cards = ComposerKinds(rawValue: 2)
}

/// 左边"＋"能打开的来源：卡片两端都有；图片 iOS 是相册与拍照，Mac 是图片文件。
enum ComposerSource { case cards, photos, camera, files }

/// 随手记、新会话与 Pi 会话回复框共用的输入框（iOS 与 Mac 同一份，文字区各用平台的文本视图包装，见 `ComposerField`）（同 ChatGPT、Claude 的"文字在上、工具在下"）：一层玻璃，里面是
/// （调用方放的）头部、带上的卡片、图片条、文字区，以及底下一整排工具：左"＋"（选卡片、相册、拍照）、调用方的小圆钮
/// （会话回复框的模型与思考强度，只在聚焦时有），右提交钮。空着又没聚焦时收成一行：＋、一行文字区（提交钮不占位）；
/// 聚焦或有内容时展开成两层，＋ 从文字区左边落到工具排左端，同一块玻璃连续变形。带上的卡片点一下看全文（长按也有预览），能"展开编辑"成这次要发的文字。
/// 调用方给草稿、占位、接受的种类和提交钮，草稿怎么处理由它们决定；给了 `submit` 时 ⌘↩ 发送（iPad 外接键盘同样）。
/// 提交钮平时有内容才出现；`showsSend` 时空着也在（收成一行时在文字区右边）——会话回复框在 Agent 跑一轮时那里是"停止"。
struct Composer<Header: View, Tools: View, Send: View>: View {
    @Binding var draft: ComposerDraft
    let prompt: String
    let label: String
    let accepts: ComposerKinds
    /// 选卡片时排在前面的项目（回复框是会话所属的项目）。
    let cardsFrom: UUID?
    /// 这张带上的卡片不能拿掉（交给 Agent 的输入框是为它打开的）。
    let keeps: UUID?
    /// 一直展开（浮起的随手记）。
    let pinnedOpen: Bool
    /// 没聚焦、没内容时收成短胶囊（＋ 与一行提示），点它照常聚焦展开（会话页在看历史时）。
    let compact: Bool
    /// 空着也露出提交钮的位置（见上）。
    let showsSend: Bool
    /// 聚焦就展开成两层。会话回复框只在有工具排（模型、思考强度）时这样：已结束的会话没有工具，聚焦了也保持一行，打了字再长。
    let expandsOnFocus: Bool
    let focus: FocusState<Bool>.Binding
    /// 这个会话此刻能用的斜杠命令：输入 "/" 时弹出面板（`PiSlashPalette`）；空表示不弹。
    let commands: [PiSlashCommand]
    private let header: Header
    /// 工具排里"＋"右边的小圆钮（会话回复框的模型与思考强度），只在聚焦时出现。
    private let tools: Tools
    private let send: Send
    private let submit: (() -> Void)?
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
    /// "＋"在一行与两层之间挪位时是同一颗（连续移动）。
    @Namespace private var layout

    init(
        draft: Binding<ComposerDraft>, prompt: String, label: String, focus: FocusState<Bool>.Binding,
        accepts: ComposerKinds = [.images, .cards], cardsFrom: UUID? = nil, pinnedOpen: Bool = false, compact: Bool = false,
        keeps: UUID? = nil, showsSend: Bool = false, expandsOnFocus: Bool = true, commands: [PiSlashCommand] = [], submit: (() -> Void)? = nil,
        @ViewBuilder header: () -> Header, @ViewBuilder tools: () -> Tools, @ViewBuilder send: () -> Send
    ) {
        _draft = draft
        self.expandsOnFocus = expandsOnFocus
        self.keeps = keeps
        self.commands = commands
        self.showsSend = showsSend
        self.submit = submit
        self.prompt = prompt
        self.label = label
        self.focus = focus
        self.accepts = accepts
        self.cardsFrom = cardsFrom
        self.pinnedOpen = pinnedOpen
        self.compact = compact
        self.header = header()
        self.tools = tools()
        self.send = send()
    }

    /// 单行时输入框高 50（字行 + 上下各 14），圆角取一半成胶囊；左下的 ＋ 与右下的提交钮同是 36 的圆，
    /// 离边 7（= 圆角 25 − 圆半径 18），与外框同心。
    private static var radius: CGFloat { 25 }
    private static var inset: CGFloat { 8 }
    /// 一个圆钮占的一格：36 的圆 + 四周的点按区与边距。
    static var slot: CGFloat { 50 }

    private var expanded: Bool { pinnedOpen || (focused && expandsOnFocus) || !draft.isEmpty(accepting: [.images, .cards]) }
    /// 收成短胶囊：一行的形态再变窄、居中，点它照常聚焦展开。
    private var shrunk: Bool { compact && !expanded && !showsSend }
    /// 短胶囊的宽：＋ 加一行短提示。
    private static var compactWidth: CGFloat { 220 }
    private var reservesSend: Bool { Send.self != EmptyView.self }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }
    private var sendVisible: Bool { reservesSend && (hasContent || showsSend) }

    /// 面板此刻列的命令；不弹时为空。
    private var paletteCommands: [PiSlashCommand] {
        guard expanded, dismissedPalette != draft.text else { return [] }
        return PiSlash.matches(draft.text, in: commands) ?? []
    }

    /// 面板打开时文字区交来的按键；返回是否已处理（没处理的照常输入）。
    private func handle(_ key: ComposerKey) -> Bool {
        let list = paletteCommands
        guard !list.isEmpty else { return false }
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
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { focused = now }
        }
        .animation(Motion.quick, value: sendVisible)
        .animation(Motion.quick, value: paletteCommands.isEmpty)
        .onChange(of: draft.text) { highlighted = 0 }
        .animation(Motion.quick, value: draft.attachments.map(\.id))
        .animation(Motion.quick, value: draft.images.map(\.id))
        .modifier(ImageSources(source: $source, images: $draft.images))
        .sheet(isPresented: showing(.cards)) {
            CardPicker(project: cardsFrom) { draft.attach($0) }
        }
        .sheet(item: $previewing) { outbox in
            AttachmentSheet(outbox: outbox, expand: { expand(outbox) })
        }
        .background {
            if let submit, hasContent { Button("发送", action: submit).keyboardShortcut(.return, modifiers: .command).hidden() }
        }
#if DEBUG
        .task { await DebugScene.presetComposer($draft, source: $source, store: workspace.services.store) }
#endif
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { header.transition(.opacity) }
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
                    text: $draft.text, prompt: prompt, label: label, maxLines: expanded ? 6 : 1, ink: palette.ink, focus: focus, keys: handle)
                    .focused(focus)
                    .padding(.leading, !expanded && !accepts.isEmpty ? 2 : 18).padding(.trailing, !expanded && sendVisible ? 2 : 18)
                    .padding(.top, 14).padding(.bottom, expanded ? 4 : 14)
                    .frame(minHeight: expanded ? nil : Self.slot)
                if !expanded, sendVisible { sendSlot }
            }
            if expanded {
                HStack(spacing: 0) {
                    if !accepts.isEmpty { plus }
                    if focused { tools.transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity)) }
                    Spacer(minLength: 0)
                    if reservesSend { sendSlot }
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
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), interactive: !expanded)
        .frame(maxWidth: .infinity)
    }

    private func showing(_ target: ComposerSource) -> Binding<Bool> {
        Binding(
            get: { source == target },
            set: { if !$0, source == target { source = nil } })
    }

    /// 提交钮的位置一直留着：有内容才放进来，输入框的宽度不随它变，文字不会因此重排。
    private var sendSlot: some View {
        ZStack {
            if sendVisible { send.transition(.scale(scale: 0.6).combined(with: .opacity)) }
        }
        .frame(width: Self.slot, height: Self.slot)
    }

    private var plus: some View {
        Menu {
            if accepts.contains(.cards) { Button("选灵感或任务", systemImage: "rectangle.on.rectangle") { source = .cards } }
            if accepts.contains(.images) {
                #if os(iOS)
                Button("相册", systemImage: "photo.on.rectangle") { source = .photos }
                if CameraPicker.isAvailable { Button("拍照", systemImage: "camera") { source = .camera } }
                #else
                Button("图片文件…", systemImage: "photo") { source = .files }
                #endif
            }
        } label: {
            CircleGlyph(systemImage: "plus", ink: palette.ink, fill: palette.fill)
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
            if outbox.card != keeps {
                Button("不带了", systemImage: "xmark") { drop(outbox) }
                    .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                    .frame(width: 44, height: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
        }
        .background(palette.fill, in: shape)
        #if os(iOS)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            menu(outbox)
        } preview: {
            AttachmentBody(content: outbox.content).frame(width: 340).frame(maxHeight: 460)
        }
        #else
        .contextMenu { menu(outbox) }
        #endif
    }

    @ViewBuilder private func menu(_ outbox: Outbox) -> some View {
        if outbox.card != keeps {
            Button("展开编辑", systemImage: "text.cursor") { expand(outbox) }
            Button("不带了", systemImage: "xmark", role: .destructive) { drop(outbox) }
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
}

extension Composer where Tools == EmptyView {
    init(
        draft: Binding<ComposerDraft>, prompt: String, label: String, focus: FocusState<Bool>.Binding,
        accepts: ComposerKinds = [.images, .cards], cardsFrom: UUID? = nil, pinnedOpen: Bool = false, compact: Bool = false,
        @ViewBuilder header: () -> Header, @ViewBuilder send: () -> Send
    ) {
        self.init(
            draft: draft, prompt: prompt, label: label, focus: focus, accepts: accepts, cardsFrom: cardsFrom, pinnedOpen: pinnedOpen,
            compact: compact, header: header, tools: { EmptyView() }, send: send)
    }
}

/// 输入框里两个角上的圆钮（看得见的 36，点得到的 44；Mac 底部输入栏一行高，用 28 / 40）：＋ 与提交钮同一个。
private struct CircleGlyph: View {
    let systemImage: String
    let ink: Color
    let fill: Color
    var size = SubmitGlyph.Size.regular

    var body: some View {
        Image(systemName: systemImage).font(size == .regular ? .body.weight(.semibold) : .system(size: 13, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: size.diameter, height: size.diameter)
            .background(fill, in: .circle)
            .frame(width: size.target, height: size.target)
            .contentShape(.circle)
    }
}

/// 输入框右下角的提交钮：存下（记成灵感）是打勾，发出（交给 Agent、回复、开新会话）是向上箭头——
/// 两种动作长得不一样，记下不会被看成发出。能按时靛青实心（主动作），按不了（同步不通、正在提交）时淡；
/// 旁边另有主钮时（Mac 随手记里能一按就发的发送钮）`prominent` 为 false，是墨色淡底的次钮。
struct SubmitGlyph: View {
    enum Action {
        case save, send
        var symbol: String { self == .save ? "checkmark" : "arrow.up" }
    }

    enum Size {
        case regular, small
        var diameter: CGFloat { self == .regular ? 36 : 28 }
        var target: CGFloat { self == .regular ? 44 : 40 }
    }

    let action: Action
    let enabled: Bool
    var prominent = true
    var size = Size.regular
    @Environment(\.palette) private var palette

    init(_ action: Action, enabled: Bool, prominent: Bool = true, size: Size = .regular) {
        self.action = action
        self.enabled = enabled
        self.prominent = prominent
        self.size = size
    }

    var body: some View {
        let primary = enabled && prominent
        CircleGlyph(
            systemImage: action.symbol, ink: primary ? palette.onSignature : enabled ? palette.ink : palette.ink3,
            fill: primary ? palette.signature : palette.fill, size: size)
            .animation(Motion.quick, value: primary)
    }
}

/// 输入框右下角的停止钮（Agent 跑一轮时代替提交钮）：墨色实心方块；停止请求已发出、这一轮还没歇下时换成转圈，不能再点。
struct StopGlyph: View {
    let stopping: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if stopping {
                ProgressView().controlSize(.small).tint(palette.ink2).frame(width: 36, height: 36).background(palette.fill, in: .circle)
            } else {
                Image(systemName: "stop.fill").font(.caption.weight(.bold)).foregroundStyle(palette.paper)
                    .frame(width: 36, height: 36).background(palette.ink, in: .circle)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .animation(Motion.quick, value: stopping)
    }
}

/// 选来的一张图：相册里的 HEIC 等格式转成 JPEG（Pi 与大多数应用不认 HEIC），PNG 与 JPEG 原样保留。
struct PickedImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: Image

    private static let quality = 0.85

    init(data: Data) {
        let keep = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF])
        #if os(iOS)
        let image = UIImage(data: data)
        self.data = keep ? data : image?.jpegData(compressionQuality: Self.quality) ?? data
        preview = image.map(Image.init(uiImage:)) ?? Image(systemName: "photo")
        #else
        let image = NSImage(data: data)
        let jpeg = keep ? nil : NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [.compressionFactor: Self.quality])
        self.data = jpeg ?? data
        preview = image.map(Image.init(nsImage:)) ?? Image(systemName: "photo")
        #endif
    }
}

/// "＋"里图片的来源，各平台系统自带的选取界面：iOS 相册与相机，Mac 选图片文件。选好的追加到图片条。
private struct ImageSources: ViewModifier {
    @Binding var source: ComposerSource?
    @Binding var images: [PickedImage]
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @State private var picked: [PhotosPickerItem] = []
    #endif

    private static let photoLimit = 9

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .photosPicker(isPresented: showing(.photos), selection: $picked, maxSelectionCount: Self.photoLimit, matching: .images)
            .fullScreenCover(isPresented: showing(.camera)) {
                CameraPicker { data in images.append(PickedImage(data: data)) }.ignoresSafeArea()
            }
            .onChange(of: picked) { load() }
        #else
        content
            .fileImporter(isPresented: showing(.files), allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                do {
                    for url in try result.get() { images.append(PickedImage(data: try Self.read(url))) }
                } catch {
                    workspace.fail(error)
                }
            }
        #endif
    }

    private func showing(_ target: ComposerSource) -> Binding<Bool> {
        Binding(get: { source == target }, set: { if !$0, source == target { source = nil } })
    }

    #if os(iOS)
    private func load() {
        let items = picked
        picked = []
        Task {
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) { images.append(PickedImage(data: data)) }
                } catch {
                    workspace.fail(error)
                }
            }
        }
    }
    #else
    /// 选文件面板给的是沙盒外的地址：读之前先拿访问权。
    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
    #endif
}

#if os(iOS)
/// 系统相机：拍一张交回 JPEG。
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85) { parent.onPick(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// 带上的卡片或任务的全文：文字、图片按原来的顺序，分割线是一条细线。`omitsTitle`：标题已写在面板顶上时正文从标题之后开始。
/// `height` 报出内容的高度，面板按它定高。
private struct AttachmentBody: View {
    let content: String
    var omitsTitle = false
    var height: Binding<CGFloat>?
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = Self.blocks(content, omitsTitle: omitsTitle)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): Text(text).font(Typography.body).foregroundStyle(palette.ink).textSelection(.enabled)
                    case .image(let hash): Thumbnail(hash: hash, height: 220, radius: 12)
                    case .split: Rectangle().fill(palette.hair).frame(height: 1)
                    }
                }
            }
            .padding(blocks.isEmpty ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height?.wrappedValue = $0 }
        }
        .background(palette.paper)
    }

    /// 相邻的文字并成一段，图片与分割线各成一块；去掉标题时删掉正文开头的标题那一行。
    private static func blocks(_ content: String, omitsTitle: Bool) -> [CueToken] {
        var blocks: [CueToken] = []
        for token in CueFormat.parse(content) {
            if case .text(let text) = token, case .text(let previous)? = blocks.last {
                blocks[blocks.count - 1] = .text(previous + text)
            } else {
                blocks.append(token)
            }
        }
        if omitsTitle, case .text(let first)? = blocks.first {
            let title = CardText(content).title
            var lines = first.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let index = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
               lines[index].trimmingCharacters(in: .whitespaces) == title {
                lines.remove(at: index)
                blocks[0] = .text(lines.joined(separator: "\n"))
            }
        }
        return blocks.compactMap { block in
            guard case .text(let text) = block else { return block }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }
}

/// 点开带上的卡片：标题在顶栏、正文在下（不重复标题），"展开编辑"把它变成这次要发的文字（只对卡片）。
/// 面板按内容定高：短卡片是一张小面板，长的到顶后可拉满屏。
private struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0
    @State private var detent = PresentationDetent.height(barHeight)

    /// Mac 的面板不随内容定高：给一个读得下的大小。
    private static let macSize = CGSize(width: 520, height: 480)
    /// 顶栏的高度，加到内容高度上就是面板高度（只有标题的卡片就只剩顶栏）。
    private static let barHeight: CGFloat = 64
    private var fitted: PresentationDetent { .height(contentHeight + Self.barHeight) }

    var body: some View {
        NavigationStack {
            AttachmentBody(content: outbox.content, omitsTitle: true, height: $contentHeight)
                .navigationTitle(CardText(outbox.content).label)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
                    if let expand {
                        ToolbarItem(placement: .confirmationAction) { Button("展开编辑", action: expand) }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([fitted, .large], selection: $detent)
        // 内容量出来后贴合它；用户拉到满屏后不再缩回
        .onChange(of: contentHeight) { if detent != .large { detent = fitted } }
        #else
        .frame(width: Self.macSize.width, height: Self.macSize.height)
        #endif
    }
}
