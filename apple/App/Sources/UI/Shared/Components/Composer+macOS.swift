#if os(macOS)
import AppKit
import CueText
import SwiftUI

extension PickedImage {
    init(data: Data) {
        let jpeg = Self.keeps(data) ? nil : NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [.compressionFactor: Self.quality])
        self.init(data: jpeg ?? data, preview: NSImage(data: data).map(Image.init(nsImage:)) ?? Image(systemName: "photo"))
    }
}

extension ComposerSource {
    static var imageChoices: [(title: String, symbol: String, source: ComposerSource)] { [("图片文件…", "photo", .files)] }
}

/// "＋"里图片的来源：选图片文件，选好的追加到图片条。
struct ImageSources: ViewModifier {
    @Binding var source: ComposerSource?
    @Binding var images: [PickedImage]
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
            .onChange(of: source) {
                guard source == .files else { return }
                source = nil
                Task {
                    do {
                        for data in try await FilePicker.images() { images.append(PickedImage(data: data)) }
                    } catch {
                        workspace.fail(error)
                    }
                }
            }
    }
}

extension View {
    func attachmentContextMenu(_ outbox: Outbox, shape: some Shape, @ViewBuilder menu: () -> some View) -> some View {
        contextMenu { menu() }
    }
}

/// 点开带上的卡片：标题在顶栏、正文在下（不重复标题），"展开编辑"把它变成这次要发的文字（只对卡片）。
/// 面板宽固定、高随内容，最高到 `macSize`，再长就在里面滚。
struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: (() -> Void)?
    @Environment(\.palette) private var palette
    @State private var contentHeight: CGFloat = 0

    private static let macSize = CGSize(width: 520, height: 480)
    /// 面板顶上标题那一行连同上下留白的高度，加到内容高度上就是面板高度。
    private static let macBar: CGFloat = 56

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: CardText(outbox.content).label) {
                if let expand { Button("展开编辑", action: expand) }
            }
            AttachmentBody(content: outbox.content, omitsTitle: true, height: $contentHeight)
        }
        .padding(.top, 18)
        .frame(width: Self.macSize.width, height: min(Self.macSize.height, contentHeight + Self.macBar))
        .background(palette.desk)
    }
}
#endif
