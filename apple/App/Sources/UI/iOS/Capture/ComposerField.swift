#if os(iOS)
import CueEditor
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 输入框里的多行文字区。不用 `TextField(axis: .vertical)`：输入法组合期拼音整串折行、定字后收回，撑满最大行数后
/// 内部文字每次都瞬间跳一整行，SwiftUI 的文本框不给滚动的接口；这里的滚动改成短动画，高度由 `sizeThatFits` 决定。
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    let label: String
    let maxLines: Int
    let ink: Color
    let focus: FocusState<Bool>.Binding
    /// 外接键盘的方向键、↩/Tab、Esc 先交给调用方；返回 true 表示已处理。
    var keys: (ComposerKey) -> Bool = { _ in false }
    /// nil 是此刻用不了。
    var shortcut: (ReplyShortcut) -> (() -> Void)? = { _ in nil }
    /// nil 是不收附件，剪贴板里的照常当文字粘。
    var files: (([IncomingFile]) -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 整个输入框被停用时（开会话的请求在路上）字也不能改：那时改的进不了已发出的请求。
    @Environment(\.isEnabled) private var enabled

    static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return GrowingTextView.rulerHeight(font: Typography.readingFont(for: traits), paragraph: Typography.readingParagraph(for: traits), lines: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> GrowingTextView {
        let view = GrowingTextView(pasteboard: workspace.services.pasteboard)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.showsHorizontalScrollIndicator = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: GrowingTextView, context: Context) {
        context.coordinator.parent = self
        view.applyTypography(UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
        // 组合期的文字已经在 `text` 里；只在外部改写（回到会话恢复草稿、发送后清空、展开编辑、编辑后重发）时才写回，免得打断输入法。
        // 外部改写赢过组合期：没定字就发出时拼音已随这句发出去，先结束组合（定字那一下不回写草稿）再写，框里不留它、之后也不被定字写回草稿。
        // 外部写进来的光标放到末尾、排好后让末尾露出来：接着写的地方在末尾，撑满行数时看见的是最后几行而不是开头
        if text != context.coordinator.sent {
            context.coordinator.sent = text
            if view.markedTextRange != nil {
                context.coordinator.writing = true
                view.unmarkText()
                context.coordinator.writing = false
            }
            view.text = text
            view.textChanged()
            view.layOutAll()
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            view.revealsEnd = true
            view.setNeedsLayout()
        }
        view.setPrompt(prompt)
        if view.isEditable != enabled { view.isEditable = enabled }
        view.placeholder.isHidden = !view.text.isEmpty
        // 只在颜色真的变了时设：设一次就给整篇文字重铺颜色、作废排版（每次更新都设时，几百行的草稿每个字多花好几毫秒）
        if ink != context.coordinator.ink {
            context.coordinator.ink = ink
            view.textColor = UIColor(ink)
        }
        view.placeholder.textColor = UIColor(palette.ink3)
        view.accessibilityLabel = label
        view.maxLines = maxLines
        view.animatesScroll = !reduceMotion
        view.keys = keys
        view.shortcut = shortcut
        view.files = files
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: GrowingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let ideal = view.fittingHeight(width: width)
        let height = min(ideal, max(Self.lineHeight(typeSize), proposal.height ?? ideal))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        /// 上次交给 `text` 的那一串：绑定原样传回时是同一块存储，比较不用逐字（更新时拿它判断是不是外部改写，不拿文字区的字比）。
        var sent = ""
        var ink: Color?
        /// 正在写外部改写的文字：这期间文字区报的变化不是你打的。
        var writing = false
        init(_ parent: ComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !writing, let view = view as? GrowingTextView else { return }
            view.placeholder.isHidden = !view.text.isEmpty
            view.textChanged()
            let text = String(native: view.textStorage.string as NSString)
            sent = text
            // 高度跟着文字一起走动画：拼音换行、定字收回每次都差一整行
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: parent.reduceMotion)) { parent.text = text }
        }
    }
}

final class GrowingTextView: UITextView {
    let placeholder = UILabel()
    var maxLines = 1
    var animatesScroll = true
    var keys: (ComposerKey) -> Bool = { _ in false }
    var shortcut: (ReplyShortcut) -> (() -> Void)? = { _ in nil }
    var files: (([IncomingFile]) -> Void)?
    /// 与复制写进的是同一个剪贴板（`AppServices.pasteboard`）。
    let pasteboard: UIPasteboard
    var revealsEnd = false { didSet { revealedHeight = nil } }
    private var revealedHeight: CGFloat?

    private var paragraph: NSParagraphStyle { typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default }

    func applyTypography(_ traits: UITraitCollection) {
        let nextFont = Typography.readingFont(for: traits)
        let nextParagraph = Typography.readingParagraph(for: traits)
        guard font != nextFont || paragraph != nextParagraph else { return }
        font = nextFont
        placeholder.font = nextFont
        let attributes: [NSAttributedString.Key: Any] = [.font: nextFont, .paragraphStyle: nextParagraph]
        textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        typingAttributes.merge(attributes) { _, value in value }
        setPrompt(placeholder.text ?? "")
        heights.textChanged()
        revealedHeight = nil
        layOutAll()
        invalidateIntrinsicContentSize()
    }

    func setPrompt(_ text: String) {
        let content = NSAttributedString(string: text, attributes: [.font: font!, .paragraphStyle: paragraph])
        guard placeholder.attributedText != content else { return }
        placeholder.attributedText = content
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    private var placeholderInset: CGFloat { caretRect(for: beginningOfDocument).maxX + 1 }

    private func promptSize(width: CGFloat) -> CGSize {
        placeholder.sizeThatFits(CGSize(width: max(0, width - placeholderInset), height: .greatestFiniteMagnitude))
    }

    /// 排满 `maxLines` 行中文量出来的高度（中文行比西文行高，首行与后续行也不一样），撑满时最后一行不被切一半；字号大到放不下时少排几行。
    var maxHeight: CGFloat {
        let rulerHeight = Self.rulerHeight(font: font!, paragraph: paragraph, lines: maxLines)
        // 大字号档位下 6 行会高过键盘上方放得下的空间（头部叠到文字上、最后一行被玻璃边切掉）：按整行数收到窗口高度的 3 成以内
        let pitch = rulerHeight / CGFloat(maxLines)
        let limit = (window?.bounds.height ?? .greatestFiniteMagnitude) * 0.3
        let lines = max(1, min(maxLines, Int(min(limit / pitch, CGFloat(maxLines)))))
        return lines == maxLines ? rulerHeight : ceil(pitch * CGFloat(lines))
    }

    /// 每次未命中高度缓存时使用独立的原生排版状态；末尾空行还读取 font/typingAttributes，不能只替换 attributedText。
    private static func measure(_ text: String, width: CGFloat, font: UIFont, paragraph: NSParagraphStyle) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let content = NSAttributedString(string: text, attributes: attributes)
        // SwiftUI 会用无穷宽探尺寸；原生视图的几何只能是有限值，超过文字自然宽度也不会再少换一行。
        let width = min(width, ceil(content.size().width))
        let ruler = UITextView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        ruler.textContainerInset = .zero
        ruler.textContainer.lineFragmentPadding = 0
        ruler.font = font
        ruler.attributedText = content
        ruler.typingAttributes = attributes
        ruler.layoutIfNeeded()
        return ruler.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
    private struct RulerKey: Hashable { var lines: Int; var size: CGFloat; var spacing: CGFloat }
    private static var rulerHeights: [RulerKey: CGFloat] = [:]

    static func rulerHeight(font: UIFont, paragraph: NSParagraphStyle, lines: Int) -> CGFloat {
        let key = RulerKey(lines: lines, size: font.pointSize, spacing: paragraph.lineSpacing)
        if let height = rulerHeights[key] { return height }
        let height = measure(Array(repeating: "国", count: lines).joined(separator: "\n"), width: .greatestFiniteMagnitude, font: font, paragraph: paragraph)
        rulerHeights[key] = height
        return height
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        if text.isEmpty {
            return max(Self.rulerHeight(font: font!, paragraph: paragraph, lines: 1), promptSize(width: width).height)
        }
        return heights.height(of: textStorage.string as NSString, width: width, em: font?.pointSize ?? 0, limit: maxHeight) { prefix in
            return Self.measure(prefix, width: width, font: font!, paragraph: paragraph)
        }
    }
    private var heights = ComposerHeight()

    func textChanged() {
        heights.textChanged()
        if laidOutWidth != bounds.width { layOutAll() }
    }

    /// 上次整篇排一遍时的宽度；nil 是要重排。文字区自己只排看得见的那段、其余的高度是估的，估的高度随排开的段越来越准，
    /// 光标在末尾时系统就跟着一帧帧地追着滚（几百行时每敲一个字都追好几帧）。外部写进、粘贴进一大段之后整篇排一遍，
    /// 之后打字只重排改动的那段。宽度变了不马上重排：形态动画里一帧一个宽度，每帧整篇排就卡住动画。
    private var laidOutWidth: CGFloat?
    func layOutAll() {
        laidOutWidth = nil
        setNeedsLayout()
    }

    private var pastesFiles: Bool { files != nil && PastedItem.isFile(pasteboard.types.compactMap(UTType.init)) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) && pastesFiles || super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let files, pastesFiles, case let pasted = PastedItem.files(on: pasteboard), !pasted.isEmpty {
            files(pasted)
            return
        }
        super.paste(sender)
        layOutAll()
    }

    init(pasteboard: UIPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: .zero, textContainer: nil)
        applyTypography(traitCollection)
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        if laidOutWidth == nil, window != nil, let manager = textLayoutManager {
            laidOutWidth = bounds.width
            manager.ensureLayout(for: manager.documentRange)
        }
        super.layoutSubviews()
        // 占位从光标右边起：光标画在第一个字上会压住它（系统输入框同样留出光标的宽度）
        let size = promptSize(width: bounds.width)
        placeholder.frame = CGRect(x: placeholderInset, y: 0, width: max(0, bounds.width - placeholderInset), height: size.height)
        // 没撑满行数时没有可滚的：滚动条只在内容比框高出半行以上时开（尺寸为 0 的滚动条会作为"0页"滑块进读屏树）
        showsVerticalScrollIndicator = contentSize.height - bounds.height > (font?.lineHeight ?? 0) / 2
        // 外部写进文字后让末尾露出来：按末尾的位置滚，不按内容高度（高度只量了开头，见 `ComposerHeight`；文字区自己只排看得见的那段，
        // 内容高度是估的）。高度还在随形态动画变的时候每次排版都对齐一次，高度不再变了才算完；还没有窗口（未上屏）时等上屏后的那次排版
        if revealsEnd, window != nil, bounds.height > 0 {
            if bounds.height == revealedHeight {
                revealsEnd = false
            } else {
                revealedHeight = bounds.height
                super.contentOffset = CGPoint(x: 0, y: max(0, caretRect(for: endOfDocument).maxY - bounds.height))
            }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        ReplyShortcut.menu.compactMap { key in
            guard shortcut(key) != nil else { return nil }
            let command = UIKeyCommand(
                title: key.title, action: #selector(performReplyShortcut(_:)), input: key.input,
                modifierFlags: key.shift ? [.command, .shift] : .command, propertyList: key.rawValue)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func performReplyShortcut(_ command: UIKeyCommand) {
        guard let key = (command.propertyList as? Int).flatMap(ReplyShortcut.init(rawValue:)) else { return }
        shortcut(key)?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 输入法组合期间的按键属于输入法
        let handled = markedTextRange == nil && presses.allSatisfy { press in
            guard let key = press.key, !key.modifierFlags.contains(.command) else { return false }
            return switch key.keyCode {
            case .keyboardUpArrow: keys(.up)
            case .keyboardDownArrow: keys(.down)
            case .keyboardReturnOrEnter: keys(.accept) || sends(key)
            case .keyboardTab: keys(.next)
            case .keyboardEscape: keys(.dismiss)
            default: false
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    /// 外接键盘的 ↩ 发送（空着时什么都不做），⇧↩ 照常换行；屏幕键盘的换行键不走按键事件，仍是换行。
    private func sends(_ key: UIKey) -> Bool {
        guard !key.modifierFlags.contains(.shift) else { return false }
        shortcut(.send)?()
        return true
    }

    /// 光标跟随造成的滚动（不是用户在拖）走短动画，不再瞬间跳一行。
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            guard animatesScroll, window != nil, !isTracking, !isDragging, !isDecelerating, abs(newValue.y - super.contentOffset.y) > 8 else {
                super.contentOffset = newValue
                return
            }
            Motion.Fade.animate { super.contentOffset = newValue }
        }
    }
}
#endif
