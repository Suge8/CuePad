#if canImport(UIKit)
import CueEditor
import CueText
import UIKit
import UniformTypeIdentifiers

func makePNG(width: Int = 1600, height: Int = 1000, color: UIColor = .systemTeal) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

extension CueEditorTheme {
    /// 测试用的最小主题：系统字体、固定色（分割线是纯红，便于从像素里认出来）。App 的纸页主题在 App 里，不在这个包。
    static let test = CueEditorTheme(
        font: .systemFont(ofSize: 17), titleFont: .systemFont(ofSize: 24, weight: .semibold),
        headingFont: .systemFont(ofSize: 20, weight: .semibold), codeFont: .monospacedSystemFont(ofSize: 15, weight: .regular),
        markerColor: .gray, codeBackground: UIColor.black.withAlphaComponent(0.06), textColor: .black, backgroundColor: .white,
        variableColor: .purple, variableBackground: UIColor.purple.withAlphaComponent(0.12),
        dividerColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1), dividerLabelColor: .darkGray, placeholderColor: .lightGray,
        horizontalInset: 16, verticalInset: 12, lineSpacing: 3, headingSpacing: 8, imageCornerRadius: 6, dividerHeight: 32)
}

@MainActor
final class EditorHarness {
    let store = DirectoryImageStore()
    let textView: CueTextView
    let root: UIWindow
    let nowhere = NSRange(location: NSNotFound, length: 0)

    init(width: CGFloat = 390, height: CGFloat = 700, theme: CueEditorTheme = .test) {
        textView = CueTextView(imageStore: store, theme: theme)
        // 要一个窗口：字号档位这类特征只在窗口里往下传。包的测试进程里没有场景，只能建无场景的窗口；
        // 那个构造在 iOS 26 标了弃用（为的是让 App 都挂到场景上），经 UIView 的构造建它，意思一样、不报弃用
        root = (UIWindow.self as UIView.Type).init(frame: CGRect(x: 0, y: 0, width: width, height: height)) as! UIWindow
        textView.frame = root.bounds
        root.addSubview(textView)
        root.makeKeyAndVisible()
    }

    func load(_ stored: String) {
        textView.storedText = stored
        layout()
    }

    func layout() {
        root.layoutIfNeeded()
        textView.layoutIfNeeded()
    }

    /// 让出主线程：分片布局、异步缩略图都排在主队列里。
    func pump(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 条件等待：让出主线程直到条件成立。上限只是"确实不会来了"的兜底（机器负载高时后台解码、布局会慢上几十秒），条件一成立马上返回。
    func wait(timeout: TimeInterval = 30, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            await pump(0.02)
        }
        return true
    }

    func setCaret(_ location: Int) { textView.selectedRange = NSRange(location: location, length: 0) }
    var caret: Int { textView.selectedRange.location }
    var stored: String { textView.storedText }

    func privatePasteboard() -> UIPasteboard {
        UIPasteboard(name: UIPasteboard.Name("cue-editor-tests-\(UUID().uuidString)"), create: true)!
    }

    /// 编辑器在屏幕上实际展示的各段落（TextKit 布局出来的文本元素，带展示属性）。
    func displayed() -> [NSAttributedString] {
        var paragraphs: [NSAttributedString] = []
        textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph { paragraphs.append(paragraph.attributedString) }
            return true
        }
        return paragraphs
    }
}

/// 变量高亮的可观察结果：直接问 TextKit 渲染属性哪些范围带了主题的变量背景色。
@MainActor
func highlightedRanges(in textView: CueTextView, color: UIColor) -> [NSRange] {
    let layout = textView.textLayoutManager!
    let content = layout.textContentManager!
    var ranges: [NSRange] = []
    layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
        if let background = attributes[.backgroundColor] as? UIColor, background == color {
            let location = content.offset(from: content.documentRange.location, to: range.location)
            ranges.append(NSRange(location: location, length: content.offset(from: range.location, to: range.endLocation)))
        }
        return true
    }
    return ranges
}

final class FakePasteItem: NSObject, UITextPasteItem, @unchecked Sendable {
    let itemProvider: NSItemProvider
    var localObject: Any? { nil }
    var defaultAttributes: [NSAttributedString.Key: Any] { [:] }
    private(set) var result: NSAttributedString?
    private(set) var resolved = false
    private(set) var usedDefault = false

    init(_ provider: NSItemProvider) { itemProvider = provider }

    func setResult(string: String) { result = NSAttributedString(string: string); resolved = true }
    func setResult(attributedString: NSAttributedString) { result = attributedString; resolved = true }
    func setResult(attachment: NSTextAttachment) { result = NSAttributedString(attachment: attachment); resolved = true }
    func setDefaultResult() { usedDefault = true; resolved = true }
    func setNoResult() { resolved = true }
}
#endif
