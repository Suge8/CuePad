#if os(iOS)
import SwiftUI
import UIKit

/// "选择文本"：一条回答的全文，可以像备忘录那样按住拖出任意一段去复制、查询（SwiftUI 的 `Text` 在手机上只能整段复制）。
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            SelectableText(text: text, ink: palette.ink)
                .background(palette.paper)
                .navigationTitle("选择文本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成", role: .close) { dismiss() } }
                }
        }
    }
}

/// 只读、可选的系统文本视图。
private struct SelectableText: UIViewRepresentable {
    let text: String
    let ink: Color

    private static let inset = UIEdgeInsets(top: 16, left: 20, bottom: 32, right: 20)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = Self.inset
        view.dataDetectorTypes = [.link]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.textColor = UIColor(ink)
    }
}
#endif
