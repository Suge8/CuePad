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
    let window: UIWindow
    let nowhere = NSRange(location: NSNotFound, length: 0)

    init(width: CGFloat = 390, height: CGFloat = 700, theme: CueEditorTheme = .test) {
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

    /// 条件等待：让出主线程直到条件成立。上限只是"确实不会来了"的兜底（机器负载高时后台解码、布局会慢上几十秒），条件一成立马上返回。
    func wait(timeout: TimeInterval = 30, until condition: () -> Bool) async -> Bool {
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

    /// 让各图层完成绘制：无宿主 App 的测试进程里没有显示周期，附件的绘制回调要手动触发。
    func display() {
        func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
        layout()
        display(textView.layer)
    }

    /// 屏幕上真实渲染出来的文本视图（drawHierarchy 在这种环境里画不出内容，直接渲染图层树）。
    private func renderedImage() -> CGImage? {
        display()
        return UIGraphicsImageRenderer(size: textView.bounds.size).image { context in
            textView.layer.render(in: context.cgContext)
        }.cgImage
    }

    /// 一块区域渲染后的像素（sRGB，RGBA 各 8 位）。
    private func pixels(of rect: CGRect) -> (data: [UInt8], width: Int, height: Int)? {
        guard let image = renderedImage() else { return nil }
        let scale = CGFloat(image.width) / textView.bounds.width
        let area = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: area) else { return nil }
        var data = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &data, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return (data, crop.width, crop.height)
    }

    /// 一块区域的中心像素。
    func renderedCenterColor(of rect: CGRect) -> UIColor? {
        guard let (data, _, _) = pixels(of: CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1)) else { return nil }
        return UIColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255, alpha: 1)
    }

    /// 一块区域里有没有接近 `color` 的像素。
    func rendered(_ rect: CGRect, contains color: UIColor) -> Bool {
        guard let (data, width, height) = pixels(of: rect) else { return false }
        var target: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        color.getRed(&target.r, green: &target.g, blue: &target.b, alpha: nil)
        // 色彩管理会让数值略偏：三个分量加起来离目标不到 0.6，而白底离纯色线有 2
        return stride(from: 0, to: width * height * 4, by: 4).contains { i in
            abs(CGFloat(data[i]) / 255 - target.r) + abs(CGFloat(data[i + 1]) / 255 - target.g) + abs(CGFloat(data[i + 2]) / 255 - target.b) < 0.6
        }
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
