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

@MainActor
final class EditorHarness {
    let store = DirectoryImageStore()
    let textView: CueTextView
    let window: UIWindow
    let nowhere = NSRange(location: NSNotFound, length: 0)

    init(width: CGFloat = 390, height: CGFloat = 700, theme: CueEditorTheme = .neutral) {
        textView = CueTextView(imageStore: store, theme: theme)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        textView.frame = window.bounds
        window.addSubview(textView)
        window.makeKeyAndVisible()
    }

    func load(_ stored: String) {
        textView.storedText = stored
        layout()
    }

    func layout() {
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
    }

    /// 让出主线程：分片布局、异步缩略图都排在主队列里。
    func pump(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func wait(timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            await pump(0.02)
        }
        return true
    }

    func subviews<T: UIView>(of type: T.Type) -> [T] {
        func walk(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(walk) }
        return walk(textView).compactMap { $0 as? T }
    }

    func setCaret(_ location: Int) { textView.selectedRange = NSRange(location: location, length: 0) }
    var caret: Int { textView.selectedRange.location }
    var stored: String { textView.storedText }

    func privatePasteboard() -> UIPasteboard {
        UIPasteboard(name: UIPasteboard.Name("cue-editor-tests-\(UUID().uuidString)"), create: true)!
    }

    /// 屏幕上真实渲染出来的一块区域的中心像素。
    func renderedCenterColor(of rect: CGRect) -> UIColor? {
        layout()
        let image = UIGraphicsImageRenderer(size: textView.bounds.size).image { _ in
            textView.drawHierarchy(in: textView.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return nil }
        let scale = image.scale
        guard let crop = cg.cropping(to: CGRect(x: rect.midX * scale, y: rect.midY * scale, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// 只含一张图片的行的布局矩形（文本视图坐标）。
    func imageLineFrames() -> [CGRect] {
        var frames: [CGRect] = []
        let inset = textView.textContainerInset
        textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            if (fragment.textElement as? NSTextParagraph)?.attributedString.string.trimmingCharacters(in: .newlines) == "\u{FFFC}" {
                frames.append(fragment.layoutFragmentFrame.offsetBy(dx: inset.left, dy: inset.top))
            }
            return true
        }
        return frames
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
