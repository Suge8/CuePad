#if os(macOS)
import AppKit
import CueEditor
import SwiftUI

extension ComposerSource {
    static var fileChoices: [(title: LocalizedStringResource, icon: Icon, source: ComposerSource)] { [("文件…", .file, .files)] }
}

extension ComposerMetrics {
    /// 一直展开（`ComposerForm.open`）、只有一行字时输入框的高度：会话页在回复框晚到的两帧里按它留位，对话不被顶上去。
    static let openOneLine = textTop + GrowingTextView().maxHeight + textBottomOpen + slot
}

/// "＋"里附件的来源：选文件（任意类型，图片也是），选好的交给 `add`（存好接进附件条）。
struct FileSources: ViewModifier {
    @Binding var source: ComposerSource?
    let add: ([IncomingFile]) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: source) {
                guard source == .files else { return }
                source = nil
                Task { add(await FilePicker.files().map(IncomingFile.file)) }
            }
    }
}

/// 带上的卡片：点一下看全文（`open`），右键出它的菜单。
struct AttachmentButton<Label: View>: View {
    let label: LocalizedStringResource
    let menu: [ChoiceMenu.Section]
    let open: () -> Void
    @ViewBuilder let content: () -> Label

    var body: some View {
        Button(action: open, label: content)
            .buttonStyle(PressStyle(.button))
            .accessibilityLabel(Text(label))
            .accessibilityHint("看全文")
            .contextMenu { ChoiceMenuItems(sections: menu) }
    }
}

/// 点开带上的卡片：标题在顶栏、正文在下（不重复标题），"展开编辑"把它变成这次要发的文字。
/// 面板宽固定、高随内容，最高到 `macSize`，再长就在里面滚。
struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: () -> Void
    @Environment(\.palette) private var palette
    @State private var contentHeight: CGFloat = 0

    private static let macSize = CGSize(width: 520, height: 480)
    /// 面板顶上标题那一行连同上下留白的高度，加到内容高度上就是面板高度。
    private static let macBar: CGFloat = 56

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: CardText.label(of: outbox.content)) {
                Button("展开编辑", action: expand)
            }
            AttachmentBody(content: outbox.content, height: $contentHeight)
        }
        .padding(.top, 18)
        .frame(width: Self.macSize.width, height: min(Self.macSize.height, contentHeight + Self.macBar))
        .background(palette.desk)
    }
}
#endif
