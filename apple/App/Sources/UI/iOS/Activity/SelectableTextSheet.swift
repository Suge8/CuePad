#if os(iOS)
import SwiftUI
import UIKit

/// 不用 `Text`：它在手机上只能整段复制。
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        TextSheet(title: "选择文本") { SelectableText(text: text, ink: palette.ink) }
    }
}

struct TextSheet<Content: View>: View {
    let title: LocalizedStringResource
    var hint: LocalizedStringResource?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            content
                .background(palette.paper)
                .navigationTitle(Text(title))
                .navigationSubtitle(hint.map { Text($0) } ?? Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成", role: .close) { dismiss() } }
                }
        }
    }
}

struct SelectableText: UIViewRepresentable {
    let text: String
    let ink: Color
    var notes: Notes?

    struct Notes {
        let runs: [String]
        let entry: UUID
        let marked: [ReplyNote]
        let fill: Color
        let line: Color
        let annotate: (ReplyNote) -> Void
        let open: (UUID) -> Void

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
            let annotate = UIAction(title: String(localized: "批注"), image: Icon.said.platformImage) { _ in notes.annotate(place) }
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
