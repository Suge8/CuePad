#if os(iOS)
import CueStore
import CueText
import PhotosUI
import SwiftUI

/// 随手记输入框（书架、项目、今天页底部浮着的那一个）。平时一行，占位写明记成什么、落到哪；聚焦或有内容时展开：
/// 想法 | 任务、落点项目、拍照、相册、记下。记下后收起并提示落点（点提示去那里）。文案与存法见 `CaptureCopy`、`CaptureDraft`。
struct CaptureComposer: View {
    /// 从外面打开随手记的请求（小组件、快捷键）：接住后定落点、聚焦或拍照选图，再交回 `consume` 清掉。
    var request: Navigation.Capture?
    var consume: () -> Void = {}
    /// 一直展开（随手记面板里）。
    var pinnedOpen = false
    var onSaved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var images: [PickedImage] = []
    @State private var kind = CaptureKind.idea
    /// 手动换过的落点；nil 时落在正在看的页面（项目页是该项目，其余未归档）。
    @State private var chosen: UUID??
    @State private var picking: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var draft: CaptureDraft { CaptureDraft(text: text, images: images.map(\.data), kind: kind) }
    private var project: UUID? { chosen ?? navigation.captureProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project), kind: kind) }
    private var expanded: Bool { pinnedOpen || focused || !text.isEmpty || !images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if expanded {
                HStack(spacing: 8) {
                    Picker("记成", selection: $kind) {
                        ForEach(CaptureKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer(minLength: 8)
                    destinationMenu
                }
                .transition(.opacity)
                if kind == .idea, !images.isEmpty { imageStrip }
            }
            HStack(alignment: .bottom, spacing: 4) {
                if !expanded {
                    Image(systemName: "square.and.pencil").foregroundStyle(palette.ink2).padding(.leading, 16).padding(.bottom, 15)
                        .accessibilityHidden(true)
                }
                TextField(CaptureCopy.placeholder(kind, to: destination), text: $text, axis: .vertical)
                    .lineLimit(expanded ? 1...6 : 1...1)
                    .focused($focused)
                    .accessibilityLabel("随手记")
                    .padding(.leading, expanded ? 12 : 4).padding(.vertical, 14)
                if expanded {
                    if kind == .idea {
                        if CameraPicker.isAvailable { icon("拍照", "camera") { showsCamera = true } }
                        icon("从相册选图", "photo.on.rectangle") { showsPhotos = true }
                    }
                    // 与回复框一样，有内容才出现
                    if !draft.isEmpty {
                        Button(action: save) { SendGlyph(enabled: !saving) }
                            .buttonStyle(.plain)
                            .disabled(saving)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel("记下")
                            .padding(.trailing, 2)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(expanded ? 8 : 0)
        .glass(in: .rect(cornerRadius: 25), interactive: !expanded)
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: kind)
        .animation(Motion.quick, value: draft.isEmpty)
        .background {
            // ⌘⇧N：聚焦随手记
            Button("随手记") { focused = true }.keyboardShortcut("n", modifiers: [.command, .shift]).hidden()
        }
        .photosPicker(isPresented: $showsPhotos, selection: $picking, maxSelectionCount: 9, matching: .images)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in images.append(PickedImage(data: data)) }.ignoresSafeArea()
        }
        .onChange(of: picking) { load() }
        .onChange(of: request?.id, initial: true) {
            guard let request else { return }
            begin(request)
            consume()
        }
    }

    /// 从外面打开（小组件、快捷键、相机或相册入口）：定落点，聚焦或直接拍照、选图。
    private func begin(_ capture: Navigation.Capture) {
        chosen = .some(capture.project)
        kind = .idea
        switch capture.start {
        // 接住请求时输入框可能还没进视图层级，下一轮再聚焦
        case .text: Task { focused = true }
        case .camera: showsCamera = CameraPicker.isAvailable
        case .photos: showsPhotos = true
        }
    }

    private var destinationMenu: some View {
        Menu {
            Button(kind == .idea ? CaptureCopy.inbox : "不归项目") { chosen = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { chosen = .some(item.id) } }
        } label: {
            HStack(spacing: 6) {
                Text("→").foregroundStyle(palette.ink3)
                ProjectGlyph(project: workspace.catalog?.project(project), size: 13)
                Text(destination).foregroundStyle(palette.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(palette.paper, in: .capsule)
        }
        .accessibilityLabel("记到 \(destination)")
    }

    private func icon(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(palette.ink2).frame(width: 40, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        image.preview.resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.hair))
                        Button {
                            withAnimation(Motion.quick) { images.removeAll { $0.id == image.id } }
                        } label: {
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
            try await draft.save(in: project, workspace: workspace)
            text = ""
            images = []
            chosen = nil
            focused = false
            onSaved()
        }
    }
}


extension View {
    /// 内容页（书架、项目、今天）底部浮着的随手记。只挂在这几页上，所以设置、回收站、搜索、任务、Pi 与打开的卡片上都没有它。
    func captureBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { FloatingCaptureBar() }
    }
}

/// 页面底部的随手记：报告自己在屏幕上（从外面打开随手记时就用它，不另弹面板），并接住外面的打开请求。
private struct FloatingCaptureBar: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        CaptureComposer(request: navigation.capture) { navigation.capture = nil }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .onAppear { navigation.captureBars += 1 }
            .onDisappear { navigation.captureBars -= 1 }
    }
}

/// 没有页面底部随手记时（在任务、Pi、设置、打开的卡片上从小组件或快捷键打开）弹出的面板，里面是同一个输入框。
struct CaptureSheet: View {
    let capture: Navigation.Capture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            CaptureComposer(request: capture, pinnedOpen: true) { dismiss() }.padding(16)
        }
        .presentationDetents([.medium])
        .presentationBackground(palette.desk)
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
