#if canImport(AppKit)
import AppKit

@MainActor
public final class CueEditorView: NSScrollView {
    public let textView: CueTextView

    /// 正文上面跟着正文一起滚的一块（规则页的提示条与技能字段），高由宿主量好报进来（`headerHeight`）。
    /// 摆在滚动区的可视区视图里、正文之上：可视区视图滚动时挪的是它的坐标系，里面的子视图一起走。
    public var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header { contentView.addSubview(header) }
            needsLayout = true
        }
    }

    public var headerHeight: CGFloat = 0 { didSet { if headerHeight != oldValue { applyInsets() } } }

    /// 滚动区顶上浮着的那一排的高（栏头）：内容停时从它下面开始，滚上去滑到它底下。
    public var topInset: CGFloat = 0 { didSet { if topInset != oldValue { applyInsets() } } }

    public init(files: any CueFileStore, theme: CueEditorTheme) {
        textView = CueTextView(files: files, theme: theme)
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        documentView = textView
    }

    public required init?(coder: NSCoder) { nil }

    /// 滚动区把上方留出的那截（`contentInsets.top`）的点按都算给自己，摆在那截里的正文上块要自己接
    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let header, let hit = header.hitTest(contentView.convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }

    /// 读屏只列滚动区的正文与滚动条，摆在可视区视图里的正文上块要自己报
    public override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + (header.map { [$0] } ?? [])
    }

    public override func layout() {
        super.layout()
        textView.minSize = NSSize(width: 0, height: contentSize.height - topInset - headerHeight)
        header?.frame = NSRect(x: 0, y: -headerHeight, width: contentView.bounds.width, height: headerHeight)
    }

    /// 内容不跟着跳：改上方留出的高时，滚动区自己把可视区原点挪同样多。
    private func applyInsets() {
        automaticallyAdjustsContentInsets = false
        contentInsets.top = topInset + headerHeight
        scrollerInsets.top = -headerHeight
        needsLayout = true
    }
}
#endif
