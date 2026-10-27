#if os(iOS)
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
    /// 焦点由调用方的 `.focused` 管（UIKit 文字区接得住 SwiftUI 的焦点）；Mac 的那份还要把 AppKit 侧的变化报回来。
    let focus: FocusState<Bool>.Binding
    /// 外接键盘的方向键、↩/Tab、Esc 先交给调用方（斜杠命令面板打开时用）；返回 true 表示已处理。
    var keys: (ComposerKey) -> Bool = { _ in false }
    /// 回复框的快捷键（`ReplyShortcut`）此刻要做的事；nil 是此刻用不了。外接键盘上是文字区的按键命令（按住 ⌘ 看得到）。
    var shortcut: (ReplyShortcut) -> (() -> Void)? = { _ in nil }
    /// 收下粘贴进来的图片（原图字节）；nil 是这个输入框不收图片，剪贴板里的照常当文字粘。
    var images: (([Data]) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    /// 这个字号下文字区一行中文的高（`ComposerMetrics.lineSlot`）。
    static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return GrowingTextView.rulerHeight(font: .preferredFont(forTextStyle: .body, compatibleWith: traits), lines: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> GrowingTextView {
        let view = GrowingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
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
        view.placeholder.text = prompt
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
        view.images = images
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: GrowingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: view.fittingHeight(width: width))
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
    var images: (([Data]) -> Void)?
    /// 外部刚写进文字：之后的排版里滚到末尾，直到高度不再变。
    var revealsEnd = false { didSet { revealedHeight = nil } }
    private var revealedHeight: CGFloat?

    /// 最大高度：同一字体下排满 `maxLines` 行中文量出来的高度（中文行比西文行高，首行与后续行也不一样），
    /// 撑满时最后一行不被切一半；字号大到放不下时少排几行。
    var maxHeight: CGFloat {
        let rulerHeight = Self.rulerHeight(font: font ?? .preferredFont(forTextStyle: .body), lines: maxLines)
        // 大字号档位下 6 行会高过键盘上方放得下的空间（头部叠到文字上、最后一行被玻璃边切掉）：按整行数收到窗口高度的 3 成以内
        let pitch = rulerHeight / CGFloat(maxLines)
        let limit = (window?.bounds.height ?? .greatestFiniteMagnitude) * 0.3
        let lines = max(1, min(maxLines, Int(min(limit / pitch, CGFloat(maxLines)))))
        return lines == maxLines ? rulerHeight : ceil(pitch * CGFloat(lines))
    }

    /// 量行高的那一个文字区，全部输入框共用：每个输入框各建一个是又一套 TextKit（打开回复框、随手记都要现建一次）。
    private static let ruler: UITextView = {
        let view = UITextView()
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }()
    private struct RulerKey: Hashable { var lines: Int; var size: CGFloat }
    private static var rulerHeights: [RulerKey: CGFloat] = [:]

    static func rulerHeight(font: UIFont, lines: Int) -> CGFloat {
        let key = RulerKey(lines: lines, size: font.pointSize)
        if let height = rulerHeights[key] { return height }
        ruler.font = font
        ruler.text = Array(repeating: "国", count: lines).joined(separator: "\n")
        let height = ruler.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
        rulerHeights[key] = height
        return height
    }

    /// 文字区在这个宽度下要多高：排出来的高度，最高 `maxHeight`（只排够上限的开头，量过的记着，见 `ComposerHeight`）。
    func fittingHeight(width: CGFloat) -> CGFloat {
        heights.height(of: textStorage.string as NSString, width: width, em: font?.pointSize ?? 0, limit: maxHeight) { prefix in
            Self.ruler.font = font
            Self.ruler.text = prefix
            return Self.ruler.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
    }
    private var heights = ComposerHeight()

    /// 文字变了（打字、外部写入）。宽度变过（形态动画、转屏）之后头一次打字时整篇重排一遍（见 `layOutAll`）。
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

    /// 剪贴板里有图片时"粘贴"收的是图片（交给 `images`，放进图片条）：纯文字的文字区本来不收图片，只有图片时连"粘贴"都不给。
    /// 认图和取图是同一条规则：种类属于图片。系统的 `hasImages` 不认只有 HEIC 的剪贴板，不用它。只看种类不读内容，不触发读取剪贴板的提示。
    private static func isImage(_ type: String) -> Bool { UTType(type)?.conforms(to: .image) == true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) && images != nil && UIPasteboard.general.types.contains(where: Self.isImage)
            || super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let images, UIPasteboard.general.types.contains(where: Self.isImage) {
            images(UIPasteboard.general.items.compactMap { item in
                item.first { Self.isImage($0.key) }.flatMap { ($0.value as? Data) ?? ($0.value as? UIImage)?.pngData() }
            })
            return
        }
        super.paste(sender)
        layOutAll()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
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
        let caret = caretRect(for: beginningOfDocument).maxX + 1
        placeholder.frame = CGRect(x: caret, y: 0, width: bounds.width - caret, height: placeholder.font.lineHeight)
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
            case .keyboardReturnOrEnter, .keyboardTab: keys(.accept)
            case .keyboardEscape: keys(.dismiss)
            default: false
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    /// 光标跟随造成的滚动（不是用户在拖）走短动画，不再瞬间跳一行。
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            guard animatesScroll, window != nil, !isTracking, !isDragging, !isDecelerating, abs(newValue.y - super.contentOffset.y) > 8 else {
                super.contentOffset = newValue
                return
            }
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                super.contentOffset = newValue
            }
        }
    }
}
#endif
