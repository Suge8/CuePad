#if os(macOS)
import AppKit
import SwiftUI

/// 输入框里的多行文字区（Mac）：与 iOS 那份同样的接口与行为——高度随文字长到 `maxLines` 行后在里面滚，
/// 输入法组字期间不从外面写回，空着时显示提示。焦点由调用方的 `.focused` 交给文本视图；文本视图自己拿到、交出焦点
/// （点进来、Esc）时再报回 `focus`。↩ 换行，⌘↩ 由输入框的发送快捷键接走。
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let label: String
    let maxLines: Int
    let ink: Color
    let focus: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = GrowingTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.font = GrowingTextView.bodyFont
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.focusChanged = { [weak coordinator = context.coordinator] in coordinator?.focusChanged($0) }
        let scroll = ComposerScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? GrowingTextView else { return }
        // 组字期的文字已经在 `text` 里；只在外部改写（回到会话恢复草稿、发送后清空、展开编辑、编辑后重发）时才写回，免得打断输入法。
        // 外部写进来的光标放到末尾、排好后让末尾露出来（同 iOS 那份）
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.revealsEnd = true
            scroll.needsLayout = true
        }
        view.placeholder = prompt
        view.textColor = NSColor(ink)
        view.insertionPointColor = NSColor(ink)
        view.setAccessibilityLabel(label)
        view.maxLines = maxLines
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let view = scroll.documentView as? GrowingTextView else { return nil }
        return CGSize(width: width, height: min(view.contentHeight(width: width), view.maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // 高度跟着文字一起走动画：换行、删行每次都差一整行
            withAnimation(parent.reduceMotion ? nil : Motion.snappy) { parent.text = view.string }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            view.window?.makeFirstResponder(nil)
            return true
        }

        func focusChanged(_ focused: Bool) {
            if parent.focus.wrappedValue != focused { parent.focus.wrappedValue = focused }
        }
    }
}

/// 文字区的滚动框：外部写进文字后，高度定下来的那次排版里滚到末尾。
final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let view = documentView as? GrowingTextView, view.revealsEnd, window != nil, contentView.bounds.height > 0 else { return }
        view.revealsEnd = false
        contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
}

final class GrowingTextView: NSTextView {
    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)
    var placeholder = ""
    var maxLines = 1
    var focusChanged: ((Bool) -> Void)?
    /// 外部刚写进文字：滚动区下一次排版后滚到末尾。
    var revealsEnd = false
    /// 最大高度：排满 `maxLines` 行中文量出来的高度（中文行比西文行高），撑满时最后一行不被切一半。
    var maxHeight: CGFloat { Self.height(of: Array(repeating: "国", count: maxLines).joined(separator: "\n"), width: .greatestFiniteMagnitude) }

    /// 按给定宽度排下现有文字要多高；空着时是一行的高度。
    func contentHeight(width: CGFloat) -> CGFloat {
        Self.height(of: string.isEmpty ? "国" : string, width: width)
    }

    private static func height(of string: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: string, attributes: [.font: bodyFont])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // 用到的范围含末尾换行后那一行空行
        return ceil(layout.usedRect(for: container).height)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        (placeholder as NSString).draw(at: .zero, withAttributes: [.font: Self.bodyFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// 当前输入框是否在输入法组字中（有未上屏的拼音等）：问窗口的第一响应者。
@MainActor
enum TextComposition {
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
}
#endif
