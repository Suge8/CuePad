#if os(macOS)
import AppKit
import PDFKit

/// 全屏页里的 PDF 能 ⌘F 搜（"编辑"菜单的查找三项，`MainMenu`）：系统的查找条（`NSTextFinder`）挂在 PDF 视图外面这一层，
/// 条出现在页顶那排玻璃下面、文字往下让出它的高；找到的那处滚到眼前、标黄。PDFKit 在 Mac 上没有自带的查找条，
/// 文字与位置经 `PDFFindClient` 交给查找条。
final class PDFFindHost: NSView, NSTextFinderBarContainer, NSMenuItemValidation {
    let pdf = PDFView()
    private let finder = NSTextFinder()
    private let client = PDFFindClient()
    /// 页顶那排玻璃占的高：查找条排在它下面
    var top: CGFloat = 0 { didSet { if top != oldValue { place() } } }
    /// 内容让出的上下边（页顶那排、底栏，查找条开着时再加它的高）
    var chrome = NSEdgeInsets() { didSet { place() } }

    var findBarView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let findBarView { addSubview(findBarView) }
            place()
        }
    }

    var isFindBarVisible = false {
        didSet {
            findBarView?.isHidden = !isFindBarVisible
            place()
        }
    }

    init(document: PDFDocument?) {
        super.init(frame: .zero)
        addSubview(pdf)
        pdf.document = document
        client.pdf = pdf
        finder.client = client
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func findBarViewDidChangeHeight() { place() }

    /// 上屏就拿键盘：⌘F、⌘G 经响应链从 PDF 视图走到这里（下面盖着的输入框不再要回焦点，`yieldsFocusWhenCovered`）。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(pdf)
    }

    func contentView() -> NSView? { pdf.documentView }

    override func layout() {
        super.layout()
        place()
    }

    /// PDF 铺满、查找条贴在页顶那排下面，内容往下让出它的高：查找条开合、页顶变了当场排。
    private func place() {
        pdf.frame = bounds
        var bar: CGFloat = 0
        if let findBarView, !findBarView.isHidden {
            bar = findBarView.frame.height
            findBarView.frame = CGRect(x: 0, y: top, width: bounds.width, height: bar)
        }
        guard let scroll = pdf.documentView?.enclosingScrollView else { return }
        let insets = NSEdgeInsets(top: chrome.top + bar, left: 0, bottom: chrome.bottom, right: 0)
        guard scroll.contentInsets.top != insets.top || scroll.contentInsets.bottom != insets.bottom else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = insets
    }

    /// 查找三项经响应链从 PDF 视图走到这里（菜单项的 tag 是 `NSTextFinder.Action`）。
    override func performTextFinderAction(_ sender: Any?) {
        guard let action = (sender as? NSValidatedUserInterfaceItem).flatMap({ NSTextFinder.Action(rawValue: $0.tag) }) else { return }
        client.reload()
        finder.performAction(action)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)), let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        client.reload()
        return finder.validateAction(action)
    }
}

/// PDF 的文字按页接成一串交给查找条：第几个字落在哪一页的哪个字、在屏上哪一块，都按这串的位置换算。
/// 找到的那处由查找条画系统的黄色提示框，框里的字由这里从页面画（PDF 视图分块画，查找条自己截不到字）。
final class PDFFindClient: NSObject, NSTextFinderClient {
    weak var pdf: PDFView?
    private(set) var string = ""
    /// 每页在这串里从哪起（最后多一个总长）
    private var starts: [Int] = [0]

    /// 文档换了或第一次搜前读一遍各页的文字（页与页之间隔一个换行，跨页的词不当一个）。
    func reload() {
        guard let document = pdf?.document, starts.count - 1 != document.pageCount || string.isEmpty else { return }
        var text = "", starts = [0]
        for index in 0..<document.pageCount {
            text += (document.page(at: index)?.string ?? "") + "\n"
            starts.append((text as NSString).length)
        }
        string = text
        self.starts = starts
    }

    func stringLength() -> Int { (string as NSString).length }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: stringLength())
        return pdf?.documentView ?? NSView()
    }

    var firstSelectedRange: NSRange { range(of: pdf?.currentSelection) ?? NSRange(location: 0, length: 0) }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue, let selection = selection(range) else { return pdf?.clearSelection() ?? () }
            pdf?.setCurrentSelection(selection, animate: false)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let selection = selection(range) else { return }
        pdf?.go(to: selection)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let pdf, let document = pdf.document else { return [] }
        return pdf.visiblePages.map { page in
            let index = document.index(for: page)
            return NSValue(range: NSRange(location: starts[index], length: starts[index + 1] - starts[index]))
        }
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let pdf, let content = pdf.documentView, let selection = selection(range) else { return nil }
        return selection.pages.map { NSValue(rect: content.convert(pdf.convert(selection.bounds(for: $0), from: $0), from: pdf)) }
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let pdf, let selection = selection(range), let context = NSGraphicsContext.current?.cgContext else { return }
        for page in selection.pages {
            // 页面坐标到内容视图坐标：内容视图是翻转的，缩放在外面的滚动视图上（多半是 1:1，照换算取）
            let point = { (p: CGPoint) in view.convert(pdf.convert(p, from: page), from: pdf) }
            let origin = point(.zero), unit = point(CGPoint(x: 1, y: 1))
            context.saveGState()
            context.clip(to: view.convert(pdf.convert(selection.bounds(for: page), from: page), from: pdf))
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: unit.x - origin.x, y: unit.y - origin.y)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }

    /// 这串里的一段落在 PDF 的哪些字（可以跨页）。
    private func selection(_ range: NSRange) -> PDFSelection? {
        guard let document = pdf?.document, range.length > 0, let first = page(of: range.location), let last = page(of: NSMaxRange(range) - 1),
              let start = document.page(at: first), let end = document.page(at: last)
        else { return nil }
        return document.selection(
            from: start, atCharacterIndex: range.location - starts[first], to: end, atCharacterIndex: NSMaxRange(range) - 1 - starts[last])
    }

    private func range(of selection: PDFSelection?) -> NSRange? {
        guard let selection, let document = pdf?.document, let page = selection.pages.first else { return nil }
        let index = document.index(for: page)
        let local = selection.range(at: 0, on: page)
        guard local.location != NSNotFound else { return nil }
        return NSRange(location: starts[index] + local.location, length: (selection.string as NSString?)?.length ?? local.length)
    }

    private func page(of location: Int) -> Int? {
        guard location >= 0, location < stringLength() else { return nil }
        return starts.lastIndex { $0 <= location }.map { min($0, starts.count - 2) }
    }
}
#endif
