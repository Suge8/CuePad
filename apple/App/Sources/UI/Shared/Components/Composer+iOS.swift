#if os(iOS)
import CueEditor
import PhotosUI
import SwiftUI

extension ComposerSource {
    static var fileChoices: [(title: LocalizedStringResource, icon: Icon, source: ComposerSource)] {
        [("相册", .photoLibrary, .photos)] + (CameraPicker.isAvailable ? [("拍照", .camera, .camera)] : []) + [("文件", .file, .files)]
    }
}

struct FileSources: ViewModifier {
    @Binding var source: ComposerSource?
    let add: ([IncomingFile]) -> Void
    @Environment(Workspace.self) private var workspace
    @State private var picked: [PhotosPickerItem] = []

    private static let photoLimit = 9

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $source.isOn(.photos), selection: $picked, maxSelectionCount: Self.photoLimit, matching: .images)
            .fullScreenCover(isPresented: $source.isOn(.camera)) {
                CameraPicker { data in add([.data(data)]) }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $source.isOn(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): add(urls.map(IncomingFile.file))
                case .failure(let error): workspace.fail(error)
                }
            }
            .onChange(of: picked) {
                let items = picked
                picked = []
                Task {
                    for item in items {
                        do {
                            if let data = try await item.loadTransferable(type: Data.self) { add([.data(PhotoData.outgoing(data))]) }
                        } catch {
                            workspace.fail(error)
                        }
                    }
                }
            }
    }
}

/// Pi 与大多数应用不认 HEIC，相册、相机来的 HEIC 等格式转成 JPEG；PNG 与 JPEG 原样保留。
nonisolated enum PhotoData {
    static let quality = 0.85

    static func outgoing(_ data: Data) -> Data {
        let keeps = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF])
        return keeps ? data : ImageFiles.jpeg(from: data, quality: quality) ?? data
    }
}

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
            if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: PhotoData.quality) { parent.onPick(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// 走 `MenuButton`（菜单开着时输入框不随键盘跳），所以长按不浮起全文预览：点一下就是全文。
struct AttachmentButton<Label: View>: View {
    let label: LocalizedStringResource
    let menu: [ChoiceMenu.Section]
    let open: () -> Void
    @ViewBuilder let content: () -> Label

    var body: some View {
        MenuButton(sections: menu, primary: open, press: .wide, accessibilityLabel: label, hint: "看全文", label: content)
    }
}

struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: () -> Void
    @Environment(\.closePanel) private var close
    @State private var contentHeight: CGFloat = 0
    @State private var detent = PresentationDetent.height(barHeight)
    /// 卡里的文件在这张面板上看：面板开着时，挂在下面页上的全屏页弹不出来
    @State private var previewing: PreviewOpening?

    private static let barHeight: CGFloat = 64
    private var fitted: PresentationDetent { .height(contentHeight + Self.barHeight) }

    var body: some View {
        NavigationStack {
            AttachmentBody(content: outbox.content, height: $contentHeight)
                .navigationTitle(CardText.label(of: outbox.content))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                    ToolbarItem(placement: .confirmationAction) { Button("展开编辑", action: expand) }
                }
        }
        .previewPresenter($previewing, reply: nil)
        .presentationDetents([fitted, .large], selection: $detent)
        .onChange(of: contentHeight) { if detent != .large { detent = fitted } }
    }
}
#endif
