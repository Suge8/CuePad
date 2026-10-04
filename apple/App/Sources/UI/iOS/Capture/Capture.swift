#if os(iOS)
import CueStore
import CueText
import PhotosUI
import SwiftUI

/// 随手记的草稿：一段文字加若干图片，存成一张卡（文字在前，图片按顺序各占一行）。
struct CaptureDraft {
    var text: String
    var images: [Data]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    func save(in project: UUID?, workspace: Workspace) async throws -> Card {
        let files = workspace.services.store.files
        let hashes = try images.map { try files.store($0) }
        let body = [
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            hashes.map { CueFormat.imageMarkup(id: $0) }.joined(separator: "\n"),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return try await workspace.createCard(body: body, in: project)
    }
}

/// 随手记栏：点文字打开随手记，相机与相册直接带图打开；记入当前位置（项目页记入该项目，其余进未归档）。
struct CaptureBar: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Button { navigation.startCapture() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").accessibilityHidden(true)
                    Text("记下想法…").foregroundStyle(palette.ink2).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .accessibilityLabel("随手记")
            if CameraPicker.isAvailable {
                icon("拍照", "camera") { navigation.startCapture(.camera) }
            }
            icon("从相册选图", "photo.on.rectangle") { navigation.startCapture(.photos) }.padding(.trailing, 6)
        }
        .buttonStyle(.plain)
    }

    private func icon(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(palette.ink2).frame(width: 44, height: 44).contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

extension View {
    /// 内容页（书架、项目、今天）底部浮着的玻璃随手记栏。只挂在这几页上，所以设置、回收站、搜索、任务、Pi 与打开的卡片上都没有它，
    /// 不依赖系统版本（标签栏附件栏要 iOS 26.1 才能按页收起）。
    func captureBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { FloatingCaptureBar() }
    }
}

/// 随手记面板打开时收起，屏幕上任何时候只有一个输入处；也不随键盘上移（键盘是面板的）。
private struct FloatingCaptureBar: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        if navigation.capture == nil {
            CaptureBar()
                .frame(maxWidth: 560).frame(height: 50)
                .glass(in: .capsule, interactive: true)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// 随手记面板：文字 + 图片（相册、相机）存为卡片。位置默认来自打开它的页面，可以当场换。
struct CaptureSheet: View {
    let capture: Navigation.Capture
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var images: [PickedImage] = []
    @State private var project: UUID?
    @State private var picking: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var draft: CaptureDraft { CaptureDraft(text: text, images: images.map(\.data)) }

    var body: some View {
        NavigationStack {
            // 面板本身就是一张纸：不再套输入框，正文从顶部写到键盘上沿，记入位置与插图贴在键盘正上方
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("记下想法…", text: $text, axis: .vertical)
                        .accessibilityLabel("记下想法")
                        .font(.title3)
                        .lineSpacing(4)
                        .foregroundStyle(palette.ink)
                        .focused($focused)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    if !images.isEmpty { imageStrip }
                }
                .padding(.horizontal, 24).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 4) {
                    destination
                    Spacer(minLength: 0)
                    if CameraPicker.isAvailable {
                        Button("拍照", systemImage: "camera") { showsCamera = true }.frame(width: 44, height: 44)
                    }
                    Button("相册", systemImage: "photo.on.rectangle") { showsPhotos = true }.frame(width: 44, height: 44)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(palette.ink2)
                .buttonStyle(.borderless)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(palette.paper)
                .overlay(alignment: .top) { Rectangle().fill(palette.hair).frame(height: 1) }
            }
            .background(palette.paper)
            .navigationTitle("随手记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存为卡片", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.isEmpty || saving)
                }
            }
        }
        .presentationBackground(palette.paper)
        .presentationDetents([.large])
        .interactiveDismissDisabled(!draft.isEmpty)
        .photosPicker(isPresented: $showsPhotos, selection: $picking, maxSelectionCount: 9, matching: .images)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in images.append(PickedImage(data: data)) }.ignoresSafeArea()
        }
        .onChange(of: picking) { load() }
        .onAppear {
            project = capture.project
            switch capture.start {
            case .text: focused = true
            case .camera: showsCamera = CameraPicker.isAvailable
            case .photos: showsPhotos = true
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        image.preview.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.hair))
                        Button {
                            withAnimation(Motion.quick) { images.removeAll { $0.id == image.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55)).font(.title3)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                        }
                        .accessibilityLabel("移除这张图片")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    private var destination: some View {
        Menu {
            Button("未归档") { project = nil }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { project = item.id } }
        } label: {
            HStack(spacing: 6) {
                Text("记入").foregroundStyle(palette.ink2)
                ProjectGlyph(project: current, size: 13)
                Text(current?.name ?? "未归档").foregroundStyle(palette.ink)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.ink2).accessibilityHidden(true)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("记入 \(current?.name ?? "未归档")")
    }

    private var current: Project? { workspace.catalog?.project(project) }

    private func load() {
        let items = picking
        picking = []
        Task {
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        withAnimation(Motion.quick) { images.append(PickedImage(data: data)) }
                    }
                } catch {
                    workspace.fail(error)
                }
            }
        }
    }

    private func save() {
        guard !draft.isEmpty, !saving else { return }
        saving = true
        let draft = draft, project = project
        workspace.attempt {
            defer { saving = false }
            _ = try await draft.save(in: project, workspace: workspace)
            workspace.say(project == nil ? "已存进未归档" : "已存为卡片")
            dismiss()
        }
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
