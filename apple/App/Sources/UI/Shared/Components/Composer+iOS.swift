#if os(iOS)
import CueText
import PhotosUI
import SwiftUI

extension PickedImage {
    init(data: Data) {
        let image = UIImage(data: data)
        self.init(
            data: Self.keeps(data) ? data : image?.jpegData(compressionQuality: Self.quality) ?? data,
            preview: image.map(Image.init(uiImage:)) ?? Image(systemName: "photo"))
    }
}

extension ComposerSource {
    static var imageChoices: [(title: String, symbol: String, source: ComposerSource)] {
        [("相册", "photo.on.rectangle", .photos)] + (CameraPicker.isAvailable ? [("拍照", "camera", .camera)] : [])
    }
}

/// "＋"里图片的来源：相册与相机，选好的追加到图片条。
struct ImageSources: ViewModifier {
    @Binding var source: ComposerSource?
    @Binding var images: [PickedImage]
    @Environment(Workspace.self) private var workspace
    @State private var picked: [PhotosPickerItem] = []

    private static let photoLimit = 9

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $source.isOn(.photos), selection: $picked, maxSelectionCount: Self.photoLimit, matching: .images)
            .fullScreenCover(isPresented: $source.isOn(.camera)) {
                CameraPicker { data in images.append(PickedImage(data: data)) }.ignoresSafeArea()
            }
            .onChange(of: picked) {
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
            if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: PickedImage.quality) { parent.onPick(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

extension View {
    /// 带上的卡片的长按菜单：长按时浮起的预览是卡片的全文。
    func attachmentContextMenu(_ outbox: Outbox, shape: some Shape, @ViewBuilder menu: @escaping () -> some View) -> some View {
        contentShape(.contextMenuPreview, shape)
            .contextMenu(menu: menu) {
                AttachmentBody(content: outbox.content).frame(width: 340).frame(maxHeight: 460)
            }
    }
}

/// 点开带上的卡片：标题在顶栏、正文在下（不重复标题），"展开编辑"把它变成这次要发的文字（只对卡片）。
/// 面板按内容定高：短卡片是一张小面板，长的到顶后可拉满屏。
struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: (() -> Void)?
    @Environment(\.closePanel) private var close
    @State private var contentHeight: CGFloat = 0
    @State private var detent = PresentationDetent.height(barHeight)

    /// 顶栏的高度，加到内容高度上就是面板高度（只有标题的卡片就只剩顶栏）。
    private static let barHeight: CGFloat = 64
    private var fitted: PresentationDetent { .height(contentHeight + Self.barHeight) }

    var body: some View {
        NavigationStack {
            AttachmentBody(content: outbox.content, omitsTitle: true, height: $contentHeight)
                .navigationTitle(CardText(outbox.content).label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
                    if let expand {
                        ToolbarItem(placement: .confirmationAction) { Button("展开编辑", action: expand) }
                    }
                }
        }
        .presentationDetents([fitted, .large], selection: $detent)
        // 内容量出来后贴合它；用户拉到满屏后不再缩回
        .onChange(of: contentHeight) { if detent != .large { detent = fitted } }
    }
}
#endif
