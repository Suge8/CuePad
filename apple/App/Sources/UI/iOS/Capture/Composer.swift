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

/// 随手记与 Pi 会话回复框共用的输入框：一层玻璃，里面是（调用方放的）头部、带上的卡片、图片条，
/// 底下一行 ＋（选卡片、相册、拍照）、输入框、有内容才出现的发送钮；聚焦或有内容时展开头部。
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

    private static var radius: CGFloat { 25 }
    private static var inset: CGFloat { 8 }

    private var source: Binding<ComposerSource?> { outerSource ?? $ownSource }
    private var expanded: Bool { pinnedOpen || focus.wrappedValue || !draft.isEmpty(accepting: [.images, .cards]) }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { header.transition(.opacity) }
            if accepts.contains(.cards), let attachment = draft.attachment {
                chip(attachment).padding([.horizontal, .top], Self.inset).transition(.opacity)
            }
            if accepts.contains(.images), !draft.images.isEmpty {
                imageStrip.padding([.horizontal, .top], Self.inset).transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if !accepts.isEmpty { plus.padding(.leading, 3) }
                TextField(prompt, text: $draft.text, axis: .vertical)
                    .lineLimit(expanded ? 1...6 : 1...1)
                    .focused(focus)
                    .accessibilityLabel(label)
                    .padding(.leading, accepts.isEmpty ? 18 : 4).padding(.trailing, 8).padding(.vertical, 14)
                if hasContent {
                    send.padding(3).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), interactive: !expanded)
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: hasContent)
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
        .onChange(of: picked) { load() }
#if DEBUG
        .task { await DebugScene.presetComposer($draft, source: source, store: workspace.services.store) }
#endif
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
            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
                .frame(width: 36, height: 36)
                .background(palette.fill, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("添加")
    }

    /// 带上的卡片或任务：标题、图片数，可移除。
    private func chip(_ outbox: Navigation.Outbox) -> some View {
        let card = CardText(outbox.content)
        return HStack(spacing: 10) {
            Image(systemName: outbox.task == nil ? "rectangle.on.rectangle" : "checklist").foregroundStyle(palette.ink3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.nonEmpty ?? "图片").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                if !card.images.isEmpty {
                    Text("\(card.images.count) 张图片").font(.caption).foregroundStyle(palette.ink3)
                }
            }
            Spacer(minLength: 8)
            Button("不带了", systemImage: "xmark") { draft.attachment = nil }
                .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .padding(.leading, 12)
        .background(palette.fill, in: .rect(cornerRadius: Self.radius - Self.inset, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("带上：\(card.title.nonEmpty ?? "图片")")
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
#endif
