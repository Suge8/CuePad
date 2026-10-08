#if os(iOS)
import SwiftUI
import UIKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> GrowingTextView {
        let view = GrowingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: GrowingTextView, context: Context) {
        context.coordinator.parent = self
        // 组合期的文字已经在 `text` 里；只在外部改写（发送后清空、展开编辑）时才写回，免得打断输入法
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.placeholder.text = prompt
        view.placeholder.isHidden = !view.text.isEmpty
        view.textColor = UIColor(ink)
        view.accessibilityLabel = label
        view.maxLines = maxLines
        view.animatesScroll = !reduceMotion
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: GrowingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(content, view.maxHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            (view as? GrowingTextView)?.placeholder.isHidden = !view.text.isEmpty
            // 高度跟着文字一起走动画：拼音换行、定字收回每次都差一整行
            withAnimation(parent.reduceMotion ? nil : Motion.snappy) { parent.text = view.text }
        }
    }
}

final class GrowingTextView: UITextView {
    let placeholder = UILabel()
    var maxLines = 1
    var animatesScroll = true

    /// 最大高度：同一字体下排满 `maxLines` 行中文量出来的高度（中文行比西文行高，首行与后续行也不一样），
    /// 撑满时最后一行不被切一半；字号大到放不下时少排几行。
    var maxHeight: CGFloat {
        let key = "\(maxLines)|\(font?.pointSize ?? 0)"
        if key != rulerKey {
            ruler.font = font
            ruler.text = Array(repeating: "国", count: maxLines).joined(separator: "\n")
            rulerHeight = ruler.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
            rulerKey = key
        }
        // 大字号档位下 6 行会高过键盘上方放得下的空间（头部叠到文字上、最后一行被玻璃边切掉）：按整行数收到窗口高度的 3 成以内
        let pitch = rulerHeight / CGFloat(maxLines)
        let limit = (window?.bounds.height ?? .greatestFiniteMagnitude) * 0.3
        let lines = max(1, min(maxLines, Int(min(limit / pitch, CGFloat(maxLines)))))
        return lines == maxLines ? rulerHeight : ceil(pitch * CGFloat(lines))
    }

    private let ruler: UITextView = {
        let view = UITextView()
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }()
    private var rulerKey = ""
    private var rulerHeight: CGFloat = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: placeholder.font.lineHeight)
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
