#if os(macOS)
import AppKit
import CueEditor
import SwiftUI

/// 焦点由调用方的 `.focused` 交给文本视图；文本视图自己拿到、交出焦点（点进来、Esc）时再报回 `focus`。
/// ↩ 发送、⇧↩ 换行在文字区自己接（`doCommandBy`）；带 ⌘ 的回复框快捷键是主菜单"回复"里的项，经响应链交到这里（`performReplyShortcut`）。
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let label: String
    let maxLines: Int
    let ink: Color
    let focus: FocusState<Bool>.Binding
    /// 返回 true 表示已处理，不再按文本视图的默认行为走。
    var keys: (ComposerKey) -> Bool = { _ in false }
    /// nil 是此刻用不了（菜单项停用）。
    var shortcut: (ReplyShortcut) -> (() -> Void)? = { _ in nil }
    /// nil 是不收附件，剪贴板里的照常当文字粘。
    var files: (([IncomingFile]) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    /// Mac 的字号不跟系统的动态字号走。
    static func lineHeight(_: DynamicTypeSize) -> CGFloat { GrowingTextView.lineHeight }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = GrowingTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.font = GrowingTextView.bodyFont
        view.defaultParagraphStyle = GrowingTextView.paragraph
        view.typingAttributes = GrowingTextView.attributes(ink)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.focusChanged = { [weak coordinator = context.coordinator, weak view] _ in
            if let view { coordinator?.focusChanged(view) }
        }
        view.shortcut = { [weak coordinator = context.coordinator] in coordinator?.parent.shortcut($0) }
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
        // 外部改写赢过组字期，先让输入法丢掉没上屏的那串。外部写进来的光标放到末尾、排好后让末尾露出来
        if text != context.coordinator.sent {
            context.coordinator.sent = text
            if view.hasMarkedText() {
                context.coordinator.writing = true
                view.inputContext?.discardMarkedText()
                view.unmarkText()
                context.coordinator.writing = false
            }
            view.string = text
            // 整篇重铺的属性要带上字色：只铺字体与段落时颜色被清掉、落回黑色（深色下草稿字发黑），之后接着打的字也照它的属性继承成黑的
            view.textStorage?.setAttributes(GrowingTextView.attributes(ink), range: NSRange(location: 0, length: (text as NSString).length))
            view.textChanged()
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.revealsEnd = true
            scroll.needsLayout = true
        }
        view.placeholder = prompt
        view.placeholderColor = NSColor(palette.ink3)
        // 只在颜色真的变了时设：设一次就给整篇文字重铺颜色。
        if ink != context.coordinator.ink {
            context.coordinator.ink = ink
            view.textColor = NSColor(ink)
            view.typingAttributes = GrowingTextView.attributes(ink)
            // 光标用主色：墨色的细线在浅底上、尤其空着时几乎看不出
            view.insertionPointColor = NSColor(palette.signatureFill)
        }
        view.setAccessibilityLabel(label)
        view.maxLines = maxLines
        view.files = files
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let view = scroll.documentView as? GrowingTextView else { return nil }
        let ideal = view.fittingHeight(width: width)
        // 受限视口至少保留一行；让原生文字框负责滚动到光标，外层不裁掉正在编辑的行。
        let height = proposal.height.map { max(GrowingTextView.lineHeight, min(ideal, $0)) } ?? ideal
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        var sent = ""
        var ink: Color?
        var writing = false
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !writing, let view = notification.object as? NSTextView else { return }
            let text = String(native: view.textStorage?.string as NSString? ?? "")
            sent = text
            // 高度跟着文字一起走动画：换行、删行每次都差一整行
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: parent.reduceMotion)) { parent.text = text }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: ComposerKey? =
                switch selector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                case #selector(NSResponder.insertNewline(_:)): .accept
                case #selector(NSResponder.insertTab(_:)): .next
                case #selector(NSResponder.insertBacktab(_:)): .previous
                case #selector(NSResponder.cancelOperation(_:)): .dismiss
                default: nil
                }
            // 输入法组字期间的按键属于输入法
            if let key, !view.hasMarkedText(), parent.keys(key) { return true }
            // ↩ 与 ⇧↩ 系统都记成 insertNewline:，按修饰键分：不带 ⇧ 的发送（空着时什么都不做，不留空行），带的照常换行
            if selector == #selector(NSResponder.insertNewline(_:)), !view.hasMarkedText(), NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
                parent.shortcut(.send)?()
                return true
            }
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            view.window?.makeFirstResponder(nil)
            return true
        }

        func focusChanged(_ view: NSTextView) {
            // 两个回复框会在同一次更新里申请焦点；窗口换完后读取真实响应者，不能回报中途的 true 或排队的旧 false。
            Task { @MainActor [weak view] in
                guard let view else { return }
                self.report(view.window?.firstResponder === view)
            }
        }

        private func report(_ focused: Bool) {
            if parent.focus.wrappedValue != focused { parent.focus.wrappedValue = focused }
        }
    }
}

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
    /// 与气泡里的字同一号：写下的这句发出去就是对话里的那颗气泡
    static let bodyFont = Typography.readingFont
    /// 行距也同气泡（`Typography.readingLineSpacing`）：多行时不比对话挤，发出去节奏不突变。
    static let paragraph = Typography.readingParagraph
    private static let metrics: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: paragraph]
    static func attributes(_ ink: Color) -> [NSAttributedString.Key: Any] { metrics.merging([.foregroundColor: NSColor(ink)]) { $1 } }
    var placeholder = ""
    var placeholderColor = NSColor.clear
    var maxLines = 1
    var focusChanged: ((Bool) -> Void)?
    var shortcut: (ReplyShortcut) -> (() -> Void)? = { _ in nil }
    var files: (([IncomingFile]) -> Void)?
    var revealsEnd = false
    /// 排满 `maxLines` 行中文量出来的高度（中文行比西文行高），撑满时最后一行不被切一半。
    var maxHeight: CGFloat {
        if let cached = Self.maxHeights[maxLines] { return cached }
        let height = Self.height(of: Array(repeating: "国", count: maxLines).joined(separator: "\n"), width: .greatestFiniteMagnitude)
        Self.maxHeights[maxLines] = height
        return height
    }
    static let lineHeight = height(of: "国", width: .greatestFiniteMagnitude)
    /// 量用的字体 `bodyFont` 是进程内不变的常量，所以只按行数记。
    private static var maxHeights: [Int: CGFloat] = [:]

    func fittingHeight(width: CGFloat) -> CGFloat {
        heights.height(of: textStorage?.string as NSString? ?? "", width: width, em: Self.bodyFont.pointSize, limit: maxHeight) {
            Self.height(of: $0, width: width)
        }
    }
    private var heights = ComposerHeight()

    func textChanged() { heights.textChanged() }

    private static func height(of string: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: string, attributes: metrics)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // 用到的范围含末尾换行后那一行空行
        return ceil(layout.usedRect(for: container).height)
    }

    /// 主菜单"回复"里的项（`MainMenu`，菜单项的 tag 是 `ReplyShortcut` 的值）：文字区是第一响应者时才找得到这里，
    /// 所以只在回复框聚焦时可用。
    @objc func performReplyShortcut(_ sender: NSMenuItem) {
        ReplyShortcut(rawValue: sender.tag).flatMap(shortcut)?()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performReplyShortcut(_:)) else { return super.validateMenuItem(item) }
        return ReplyShortcut(rawValue: item.tag).flatMap(shortcut) != nil
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        files == nil ? super.readablePasteboardTypes : NSPasteboard.fileTypes + super.readablePasteboardTypes
    }

    /// 有附件（规则在 `NSPasteboard.files`）就交出去，否则按文字的种类照常插：附件的种类排在前面，传进来的可能是它们。
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let found = pboard.files
        guard let files, !found.isEmpty else {
            return super.readSelection(from: pboard, type: pboard.availableType(from: super.readablePasteboardTypes) ?? type)
        }
        files(found)
        return true
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
        (placeholder as NSString).draw(at: .zero, withAttributes: [.font: Self.bodyFont, .foregroundColor: placeholderColor])
    }

    override func didChangeText() {
        super.didChangeText()
        textChanged()
        needsDisplay = true
    }
}

enum TextComposition {
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
}
#endif
