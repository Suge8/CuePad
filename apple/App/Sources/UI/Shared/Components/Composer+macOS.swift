#if os(macOS)
import AppKit
import CueEditor
import SwiftUI

extension ComposerSource {
    static var fileChoices: [(title: LocalizedStringResource, icon: Icon, source: ComposerSource)] { [("文件…", .file, .files)] }
}

extension ComposerMetrics {
    /// 会话页在回复框晚到的两帧里按它留位，对话不被顶上去。
    static let openOneLine = textTop + GrowingTextView().maxHeight + textBottomOpen + slot
}

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

struct AttachmentSheet: View {
    let outbox: Outbox
    let expand: () -> Void
    @Environment(\.palette) private var palette
    @State private var contentHeight: CGFloat = 0

    private static let macSize = CGSize(width: 520, height: 480)
    private static let macBar: CGFloat = 56

    var body: some View {
        VStack(spacing: Spacing.item) {
            PanelHeader(title: CardText.label(of: outbox.content)) {
                Button("展开编辑", action: expand)
            }
            AttachmentBody(content: outbox.content, height: $contentHeight)
        }
        .padding(.top, Spacing.block)
        .frame(width: Self.macSize.width, height: min(Self.macSize.height, contentHeight + Self.macBar))
        .background(palette.desk)
    }
}
#endif
