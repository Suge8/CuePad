#if canImport(AppKit)
import AppKit
import CryptoKit
import CueEditor
import CueText

func makePNG(width: Int = 1600, height: Int = 1000, seed: Int = 0, color: NSColor? = nil) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (color ?? NSColor(hue: CGFloat(seed % 20) / 20, saturation: 0.6, brightness: 0.9, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension CueEditorTheme {
    /// 测试用的最小主题：系统字体、固定色（分割线是纯红，便于从像素里认出来）。App 的纸页主题在 App 里，不在这个包。
    static let test = CueEditorTheme(
        font: .systemFont(ofSize: 15), titleFont: .systemFont(ofSize: 22, weight: .semibold),
        headingFont: .systemFont(ofSize: 18, weight: .semibold), codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        markerColor: .gray, codeBackground: NSColor.black.withAlphaComponent(0.06), textColor: .black, backgroundColor: .white,
        variableColor: .purple, variableBackground: NSColor.purple.withAlphaComponent(0.12),
        dividerColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), dividerLabelColor: .darkGray, placeholderColor: .lightGray,
        horizontalInset: 20, verticalInset: 16, lineSpacing: 3, headingSpacing: 8, imageCornerRadius: 6, dividerHeight: 28)
}

@MainActor
final class EditorHarness {
    let store = DirectoryImageStore()
    let editor: CueEditorView
    let window: NSWindow
    var textView: CueTextView { editor.textView }

    init(width: CGFloat = 720, height: CGFloat = 640, theme: CueEditorTheme = .test) {
        _ = NSApplication.shared
        editor = CueEditorView(imageStore: store, theme: theme)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        editor.frame = window.contentView!.bounds
        editor.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(editor)
        window.makeFirstResponder(textView)
    }

    func load(_ stored: String) {
        textView.storedText = stored
        layout()
    }

    func layout() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// 让出主线程一小段：分片布局、异步缩略图都排在主队列里，同步测试体里推进不了它们。
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

    func subviews<T: NSView>(of type: T.Type) -> [T] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(textView).compactMap { $0 as? T }
    }

    /// 只含一张图片的行的布局矩形（文本视图坐标）。
    func imageLineFrames() -> [CGRect] {
        var frames: [CGRect] = []
        let origin = textView.textContainerOrigin
        textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            if (fragment.textElement as? NSTextParagraph)?.attributedString.string.trimmingCharacters(in: .newlines) == "\u{FFFC}" {
                frames.append(fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y))
            }
            return true
        }
        return frames
    }

    /// 把文本视图的一块区域真实绘制出来后读取中心像素。
    func renderedCenterColor(of rect: CGRect) -> NSColor? {
        let rep = textView.bitmapImageRepForCachingDisplay(in: rect)!
        textView.cacheDisplay(in: rect, to: rep)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    /// 把文本视图的一块区域真实绘制出来，看里面有没有接近 `color` 的像素。
    func rendered(_ rect: CGRect, contains color: NSColor) -> Bool {
        let rep = textView.bitmapImageRepForCachingDisplay(in: rect)!
        textView.cacheDisplay(in: rect, to: rep)
        let target = color.usingColorSpace(.sRGB)!
        return (0..<rep.pixelsHigh).contains { y in
            (0..<rep.pixelsWide).contains { x in
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                // 色彩管理会让数值略偏：三个分量加起来离目标不到 0.6，而白底离纯色线有 2
                return abs(pixel.redComponent - target.redComponent) + abs(pixel.greenComponent - target.greenComponent)
                    + abs(pixel.blueComponent - target.blueComponent) < 0.6
            }
        }
    }

    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cue-editor-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func setCaret(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }
    var caret: Int { textView.selectedRange().location }
    var stored: String { textView.storedText }
}

/// 变量高亮的可观察结果：直接问 TextKit 渲染属性哪些范围带了主题的变量背景色。
@MainActor
func highlightedRanges(in textView: CueTextView, color: NSColor) -> [NSRange] {
    let layout = textView.textLayoutManager!
    let content = layout.textContentManager!
    var ranges: [NSRange] = []
    layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
        if let background = attributes[.backgroundColor] as? NSColor, background == color {
            let location = content.offset(from: content.documentRange.location, to: range.location)
            ranges.append(NSRange(location: location, length: content.offset(from: range.location, to: range.endLocation)))
        }
        return true
    }
    return ranges
}

final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    let window: NSWindow
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        self.pasteboard = pasteboard; self.location = location; self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

#endif
