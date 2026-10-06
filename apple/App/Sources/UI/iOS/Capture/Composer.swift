#if os(iOS)
import CueStore
import CueText
import PhotosUI
import SwiftUI

/// 输入框里的东西：文字、图片、带上的一张卡片或任务。存成卡片（随手记）、发给 Pi（回复）、开场的话（新会话）都是它，
/// 去处只决定怎么处理这份草稿。
struct ComposerDraft {
    var text = ""
    var images: [PickedImage] = []
    var attachment: Navigation.Outbox?

    /// 带的内容里有没有图片：自己选的，或带上的卡片里的。
    var hasImages: Bool { !images.isEmpty || !CardText(attachment?.content ?? "").images.isEmpty }

    /// 按去处接受的种类，有没有可发的东西（不接受的种类不算）。
    func isEmpty(accepting kinds: ComposerKinds) -> Bool {
        text.allSatisfy(\.isWhitespace) && (!kinds.contains(.images) || images.isEmpty) && (!kinds.contains(.cards) || attachment == nil)
    }

    /// 存储格式正文：图片文件在这里写入图片库。
    func stored(in files: AttachmentFiles) throws -> String {
        StoredBody.make(attachment: attachment?.content, text: text, imageHashes: try images.map { try files.store($0.data) })
    }
}

extension AppServices {
    /// 把草稿发给一个 Pi 会话（写投送请求）：带上的卡片或任务关联到这条请求。
    @discardableResult
    func requestMacDelivery(_ draft: ComposerDraft, to session: PiSessionState, mode: DeliveryMode) async throws -> DeliveryRequest {
        try await requestMacDelivery(
            draft.stored(in: store.files), to: session, mode: mode, card: draft.attachment?.card, task: draft.attachment?.task)
    }
}

/// 一个去处接受草稿里的哪几种东西。
struct ComposerKinds: OptionSet {
    let rawValue: Int
    static let images = ComposerKinds(rawValue: 1)
    static let cards = ComposerKinds(rawValue: 2)
}

/// 左边"＋"能打开的三个来源；外面也可以直接打开其中一个（小组件的"拍照"入口）。
enum ComposerSource { case cards, photos, camera }

/// 随手记与 Pi 会话回复框共用的输入框（同 iOS 信息 App）：左边一颗独立的圆形玻璃"＋"（选卡片、相册、拍照），
/// 与输入框的底行同高、垂直居中；右边一层玻璃，里面是（调用方放的）头部、带上的卡片、图片条、输入框与有内容才出现的发送钮；
/// 聚焦或有内容时展开头部。带上的卡片点一下看全文（长按也有预览），能"展开编辑"成这次要发的文字。
/// 调用方给草稿、占位、接受的种类和发送钮，草稿怎么处理由它们决定。
struct Composer<Header: View, Send: View>: View {
    @Binding var draft: ComposerDraft
    let prompt: String
    let label: String
    let accepts: ComposerKinds
    /// 选卡片时排在前面的项目（回复框是会话所属的项目）。
    let cardsFrom: UUID?
    /// 一直展开（随手记面板里）。
    let pinnedOpen: Bool
    let focus: FocusState<Bool>.Binding
    private let outerSource: Binding<ComposerSource?>?
    private let header: Header
    private let send: Send
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var ownSource: ComposerSource?
    @State private var picked: [PhotosPickerItem] = []
    @State private var previewing: Navigation.Outbox?

    init(
        draft: Binding<ComposerDraft>, prompt: String, label: String, focus: FocusState<Bool>.Binding,
        accepts: ComposerKinds = [.images, .cards], cardsFrom: UUID? = nil, pinnedOpen: Bool = false,
        source: Binding<ComposerSource?>? = nil, @ViewBuilder header: () -> Header, @ViewBuilder send: () -> Send
    ) {
        _draft = draft
        self.prompt = prompt
        self.label = label
        self.focus = focus
        self.accepts = accepts
        self.cardsFrom = cardsFrom
        self.pinnedOpen = pinnedOpen
        outerSource = source
        self.header = header()
        self.send = send()
    }

    /// 单行时输入框高 50（字行 + 上下各 14），圆角取一半成胶囊；＋ 是同高的圆。
    private static var radius: CGFloat { 25 }
    private static var inset: CGFloat { 8 }
    private static var gap: CGFloat { 8 }

    private var source: Binding<ComposerSource?> { outerSource ?? $ownSource }
    private var expanded: Bool { pinnedOpen || focus.wrappedValue || !draft.isEmpty(accepting: [.images, .cards]) }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }

    var body: some View {
        // 两块玻璃放进同一个容器：一起取样背景，靠近时按系统规则融合
        GlassEffectContainer(spacing: Self.gap) {
            HStack(alignment: .bottom, spacing: Self.gap) {
                if !accepts.isEmpty { plus.transition(.scale(scale: 0.6).combined(with: .opacity)) }
                field
            }
        }
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: hasContent)
        .animation(Motion.quick, value: accepts.isEmpty)
        .animation(Motion.quick, value: draft.attachment?.id)
        .animation(Motion.quick, value: draft.images.map(\.id))
        .photosPicker(isPresented: showing(.photos), selection: $picked, maxSelectionCount: 9, matching: .images)
        .fullScreenCover(isPresented: showing(.camera)) {
            CameraPicker { data in draft.images.append(PickedImage(data: data)) }.ignoresSafeArea()
        }
        .sheet(isPresented: showing(.cards)) {
            CardPicker(project: cardsFrom) { card in
                draft.attachment = Navigation.Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID)
            }
        }
        .sheet(item: $previewing) { outbox in
            AttachmentSheet(outbox: outbox, expand: outbox.task == nil ? { expand(outbox) } : nil)
        }
        .onChange(of: picked) { load() }
#if DEBUG
        .task { await DebugScene.presetComposer($draft, source: source, store: workspace.services.store) }
#endif
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { header.transition(.opacity) }
            if accepts.contains(.cards), let attachment = draft.attachment {
                chip(attachment).padding([.horizontal, .top], Self.inset).transition(.opacity)
            }
            if accepts.contains(.images), !draft.images.isEmpty {
                imageStrip.padding([.horizontal, .top], Self.inset).transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 0) {
                TextField(prompt, text: $draft.text, axis: .vertical)
                    .lineLimit(expanded ? 1...6 : 1...1)
                    .focused(focus)
                    .accessibilityLabel(label)
                    .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 14)
                if hasContent {
                    send.padding(3).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), interactive: !expanded)
    }

    private func showing(_ target: ComposerSource) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue == target },
            set: { if !$0, source.wrappedValue == target { source.wrappedValue = nil } })
    }

    private var plus: some View {
        Menu {
            if accepts.contains(.cards) { Button("选卡片", systemImage: "rectangle.on.rectangle") { source.wrappedValue = .cards } }
            if accepts.contains(.images) {
                Button("相册", systemImage: "photo.on.rectangle") { source.wrappedValue = .photos }
                if CameraPicker.isAvailable { Button("拍照", systemImage: "camera") { source.wrappedValue = .camera } }
            }
        } label: {
            Image(systemName: "plus").font(.title3.weight(.medium)).foregroundStyle(palette.ink)
                .frame(width: 2 * Self.radius, height: 2 * Self.radius)
                .glass(in: .circle, interactive: true)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("添加")
    }

    /// 带上的卡片或任务：标题、图片数，可移除；点一下看全文，长按是预览与"展开编辑"。
    private func chip(_ outbox: Navigation.Outbox) -> some View {
        let card = CardText(outbox.content)
        let shape = RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
        return HStack(spacing: 0) {
            Button { previewing = outbox } label: {
                HStack(spacing: 10) {
                    Image(systemName: outbox.task == nil ? "rectangle.on.rectangle" : "checklist").foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title.nonEmpty ?? "图片").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        if !card.images.isEmpty {
                            Text("\(card.images.count) 张图片").font(.caption).foregroundStyle(palette.ink3)
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
            Button("不带了", systemImage: "xmark") { draft.attachment = nil }
                .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .background(palette.fill, in: shape)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            if outbox.task == nil { Button("展开编辑", systemImage: "text.cursor") { expand(outbox) } }
            Button("不带了", systemImage: "xmark", role: .destructive) { draft.attachment = nil }
        } preview: {
            AttachmentBody(content: outbox.content).frame(width: 340).frame(maxHeight: 460)
        }
    }

    /// 展开编辑：卡片的文字放进输入框（接在已写的字前面）、图片放进图片条，不再作为整张卡带上，原卡片不动。
    private func expand(_ outbox: Navigation.Outbox) {
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
        draft.attachment = nil
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
                        .accessibilityLabel("移除这张图片")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    private func load() {
        let items = picked
        picked = []
        Task {
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) { draft.images.append(PickedImage(data: data)) }
                } catch {
                    workspace.fail(error)
                }
            }
        }
    }
}

extension Composer where Header == EmptyView {
    init(
        draft: Binding<ComposerDraft>, prompt: String, label: String, focus: FocusState<Bool>.Binding,
        accepts: ComposerKinds = [.images, .cards], cardsFrom: UUID? = nil, @ViewBuilder send: () -> Send
    ) {
        self.init(
            draft: draft, prompt: prompt, label: label, focus: focus, accepts: accepts, cardsFrom: cardsFrom,
            header: { EmptyView() }, send: send)
    }
}

/// 输入框里的圆形发送钮（看得见的 36，点得到的 44）：能发时墨色实心，发不出（同步不通、发送中）时淡。
struct SendGlyph: View {
    let enabled: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "arrow.up").font(.body.weight(.semibold))
            .foregroundStyle(enabled ? palette.onAccent : palette.ink3)
            .frame(width: 36, height: 36)
            .background(enabled ? palette.accent : palette.fill, in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .animation(Motion.quick, value: enabled)
    }
}

/// 选来的一张图：相册里的 HEIC 等格式转成 JPEG（Pi 与大多数应用不认 HEIC），PNG 与 JPEG 原样保留。
struct PickedImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: Image

    private static let quality = 0.85

    init(data: Data) {
        let image = UIImage(data: data)
        let keep = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF])
        self.data = keep ? data : image?.jpegData(compressionQuality: Self.quality) ?? data
        preview = image.map(Image.init(uiImage:)) ?? Image(systemName: "photo")
    }
}

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
/// 带上的卡片或任务的全文：文字、图片按原来的顺序，分割线是一条细线。
private struct AttachmentBody: View {
    let content: String
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.blocks(content).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): Text(text).font(.body).foregroundStyle(palette.ink).textSelection(.enabled)
                    case .image(let hash): Thumbnail(hash: hash, height: 220, radius: 12)
                    case .split: Rectangle().fill(palette.hair).frame(height: 1)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.paper)
    }

    /// 相邻的文字并成一段，图片与分割线各成一块。
    private static func blocks(_ content: String) -> [CueToken] {
        var blocks: [CueToken] = []
        for token in CueFormat.parse(content) {
            if case .text(let text) = token, case .text(let previous)? = blocks.last {
                blocks[blocks.count - 1] = .text(previous + text)
            } else {
                blocks.append(token)
            }
        }
        return blocks.compactMap { block in
            guard case .text(let text) = block else { return block }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }
}

/// 点开带上的卡片：全文，"展开编辑"把它变成这次要发的文字（只对卡片）。
private struct AttachmentSheet: View {
    let outbox: Navigation.Outbox
    let expand: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AttachmentBody(content: outbox.content)
                .navigationTitle(CardText(outbox.content).title.nonEmpty ?? "卡片")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
                    if let expand {
                        ToolbarItem(placement: .confirmationAction) { Button("展开编辑", action: expand) }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
