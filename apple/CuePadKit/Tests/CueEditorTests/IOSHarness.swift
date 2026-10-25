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
    /// 测试用的最小主题：系统字体、固定色。App 的纸页主题在 App 里，不在这个包。
    static let test = CueEditorTheme(
        font: .systemFont(ofSize: 17),
        headingFont: .systemFont(ofSize: 20, weight: .semibold), codeFont: .monospacedSystemFont(ofSize: 15, weight: .regular),
        markerColor: .gray, codeBackground: UIColor.black.withAlphaComponent(0.06), textColor: .black, backgroundColor: .white,
        variableColor: .purple, variableBackground: UIColor.purple.withAlphaComponent(0.12),
        imagePlaceholderColor: .lightGray,
        horizontalInset: 16, verticalInset: 12, lineSpacing: 3, headingSpacing: 8, imageCornerRadius: 6)
}

@MainActor
final class EditorHarness {
    let store = DirectoryImageStore()
    let textView: CueTextView
    /// 编辑器挂在一个普通视图下：包的测试进程（xctest）里没有场景，不建窗口。
    let root: UIView
    let nowhere = NSRange(location: NSNotFound, length: 0)

    init(width: CGFloat = 390, height: CGFloat = 700, theme: CueEditorTheme = .test) {
        textView = CueTextView(imageStore: store, theme: theme)
        root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        textView.frame = root.bounds
        root.addSubview(textView)
    }

    func layout() {
        updateTraits()
        root.layoutIfNeeded()
        textView.layoutIfNeeded()
    }

    /// 让出主线程：分片布局、异步缩略图都排在主队列里。
    func pump(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
        updateTraits()
    }

    /// 特征（字号档位、深浅色）变了以后，窗口会在下一圈把它往下传、触发变化回调；不在窗口里就由这里推一下。
    private func updateTraits() { root.updateTraitsIfNeeded() }

    func setCaret(_ location: Int) { textView.selectedRange = NSRange(location: location, length: 0) }

    func privatePasteboard() -> UIPasteboard {
        UIPasteboard(name: UIPasteboard.Name("cue-editor-tests-\(UUID().uuidString)"), create: true)!
    }
}

/// 粘贴与拖入委托给出结果的那一刻（UIKit 可能在别的线程回调）就交给等它的测试，不轮询。
final class FakePasteItem: NSObject, UITextPasteItem, @unchecked Sendable {
    let itemProvider: NSItemProvider
    var localObject: Any? { nil }
    var defaultAttributes: [NSAttributedString.Key: Any] { [:] }
    private(set) var result: NSAttributedString?
    private(set) var usedDefault = false
    private let (resolutions, resolve) = AsyncStream<Void>.makeStream()

    init(_ provider: NSItemProvider) { itemProvider = provider }

    func resolved() async { for await _ in resolutions { return } }

    func setResult(string: String) { finish(NSAttributedString(string: string)) }
    func setResult(attributedString: NSAttributedString) { finish(attributedString) }
    func setResult(attachment: NSTextAttachment) { finish(NSAttributedString(attachment: attachment)) }
    func setDefaultResult() { usedDefault = true; resolve.finish() }
    func setNoResult() { resolve.finish() }

    private func finish(_ value: NSAttributedString) {
        result = value
        resolve.finish()
    }
}
#endif
