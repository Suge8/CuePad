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
        var hashes: [String] = []
        for image in images { hashes.append(try await workspace.services.store.addImage(image).hash) }
        let body = [
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            hashes.map { CueFormat.imageMarkup(id: $0) }.joined(separator: "\n"),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return try await workspace.createCard(body: body, in: project)
    }
}

/// 标签栏上方常驻的随手记栏：点文字打开随手记，相机与相册直接带图打开。记入当前位置（项目页记入该项目，其余进未归档）。
struct CaptureAccessory: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 0) {
            Button { navigation.startCapture() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").accessibilityHidden(true)
                    Text(placement == .inline ? "记一笔" : "记下想法…").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .accessibilityLabel("随手记")
            .accessibilityHint(navigation.captureProject == nil ? "记入未归档" : "记入当前项目")
            if placement != .inline {
                if CameraPicker.isAvailable {
                    iconButton("拍照", "camera") { navigation.startCapture(.camera) }
                }
                iconButton("从相册选图", "photo.on.rectangle") { navigation.startCapture(.photos) }
                    .padding(.trailing, 6)
            }
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

/// 随手记面板：文字 + 图片（相册、相机）存为卡片。位置默认来自打开它的页面，可以当场换。
struct CaptureSheet: View {
    let capture: Navigation.Capture
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var images: [PickedImage] = []
    @State private var project: UUID?
    @State private var projects: [Project]?
    @State private var picking: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var draft: CaptureDraft { CaptureDraft(text: text, images: images.map(\.data)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("记下想法…", text: $text, axis: .vertical)
                        .font(.body)
                        .lineLimit(5...14)
                        .focused($focused)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .paper(radius: 14)
                    if !images.isEmpty { imageStrip }
                    HStack(spacing: 8) {
                        destination
                        Spacer(minLength: 0)
                        if CameraPicker.isAvailable {
                            Button("拍照", systemImage: "camera") { showsCamera = true }
                        }
                        Button("相册", systemImage: "photo.on.rectangle") { showsPhotos = true }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.borderless)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.desk)
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
        .presentationDetents([.medium, .large])
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
        .observing(services.store, [.projects], into: $projects) { try $0.projects() }
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
            ForEach(projects ?? []) { item in Button(item.name) { project = item.id } }
        } label: {
            HStack(spacing: 6) {
                Text("记入").foregroundStyle(.secondary)
                ProjectGlyph(project: current, size: 13)
                Text(current?.name ?? "未归档").foregroundStyle(palette.ink)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("记入 \(current?.name ?? "未归档")")
    }

    private var current: Project? { projects?.first { $0.id == project } }

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
