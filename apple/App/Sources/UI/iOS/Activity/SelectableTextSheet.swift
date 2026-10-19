#if os(iOS)
import SwiftUI
import UIKit

/// "选择文本"：一条消息的全文，可以像备忘录那样按住拖出任意一段去复制、查询（SwiftUI 的 `Text` 在手机上只能整段复制）。
/// Cue 页的话用它；会话里的回答用带批注的那一张（`ReplyTextSheet`）。
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        TextSheet(title: "选择文本") { SelectableText(text: text, ink: palette.ink) }
    }
}

/// 可选文本页的外框：标题、可选的一行提示（标题下面），右上角"完成"。
struct TextSheet<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            content
                .background(palette.paper)
                .navigationTitle(title)
                .navigationSubtitle(hint ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成", role: .close) { dismiss() } }
                }
        }
    }
}

/// 只读、可选的系统文本视图。给了 `notes` 时可以批注：编辑菜单最前面加"批注"，批注过的几处高亮、点它打开那一条。
struct SelectableText: UIViewRepresentable {
    let text: String
    let ink: Color
    var notes: Notes?

    /// 一条回答的批注：`text` 是 `runs` 用 `runGap` 连起来的全文，选区按它换算回第几段、段内偏移（`ReplyNote`）。
    struct Notes {
        let runs: [String]
        let entry: UUID
        /// 这条回答已有的批注。
        let marked: [ReplyNote]
        let fill: Color
        let line: Color
        /// 选中的一处（还不知道是不是已经批注过）。
        let annotate: (ReplyNote) -> Void
        let open: (UUID) -> Void

        /// 选区所在的那一处：截到起点那一段（起点落在段间空行里时是下一段）；选区里没有正文时为 nil。
        func place(_ range: NSRange) -> ReplyNote? {
            var start = 0
            for (run, text) in runs.enumerated() {
                let length = text.utf16.count
                let lower = max(range.location, start), upper = min(NSMaxRange(range), start + length)
                if lower < upper {
                    let local = NSRange(location: lower - start, length: upper - lower)
                    return ReplyNote(entry: entry, run: run, location: local.location, quote: (text as NSString).substring(with: local))
                }
                start += length + SelectableText.runGap.utf16.count
            }
            return nil
        }

        /// 每条批注在全文里的那一处；那一处已不是摘录时不画（同 `MarkdownText`）。
        func ranges() -> [(UUID, NSRange)] {
            var starts: [Int] = [], start = 0
            for run in runs {
                starts.append(start)
                start += run.utf16.count + SelectableText.runGap.utf16.count
            }
            return marked.compactMap { note in
                guard note.run < runs.count, NSMaxRange(note.range) <= runs[note.run].utf16.count,
                      (runs[note.run] as NSString).substring(with: note.range) == note.quote else { return nil }
                return (note.id, NSRange(location: starts[note.run] + note.location, length: note.range.length))
            }
        }
    }

    static let runGap = "\n\n"
    private static let inset = UIEdgeInsets(top: 16, left: 20, bottom: 32, right: 20)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = Self.inset
        view.dataDetectorTypes = [.link]
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.notes = notes
        // 字与高亮没变时不重设：重设会清掉正在拖的选区
        let styled = styled()
        guard styled != context.coordinator.shown else { return }
        context.coordinator.shown = styled
        view.attributedText = styled
    }

    private func styled() -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let text = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor(ink)])
        guard let notes else { return text }
        for (id, range) in notes.ranges() {
            text.addAttributes([
                .backgroundColor: UIColor(notes.fill),
                .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                .underlineColor: UIColor(notes.line),
                // 系统的文本项：点它走 `primaryActionFor`，不像链接那样换色
                .textItemTag: id.uuidString,
            ], range: range)
        }
        return text
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var notes: Notes?
        var shown: NSAttributedString?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let notes, let place = notes.place(range) else { return nil }
            let annotate = UIAction(title: "批注", image: Icon.said.platformImage) { _ in notes.annotate(place) }
            return UIMenu(children: [annotate] + suggestedActions)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .tag(let tag) = textItem.content, let id = UUID(uuidString: tag), let notes else { return defaultAction }
            return UIAction { _ in notes.open(id) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            if case .tag = textItem.content { return nil }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
    }
}
#endif
