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
    /// 测试用的最小主题：系统字体、固定色。App 的纸页主题在 App 里，不在这个包。
    static let test = CueEditorTheme(
        font: .systemFont(ofSize: 15),
        headingFont: .systemFont(ofSize: 18, weight: .semibold), codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        captionFont: .systemFont(ofSize: 12), fileGlyphSize: 20,
        markerColor: .gray, codeBackground: NSColor.black.withAlphaComponent(0.06), textColor: .black, backgroundColor: .white,
        variableColor: .purple, variableBackground: NSColor.purple.withAlphaComponent(0.12),
        imagePlaceholderColor: .lightGray,
        horizontalInset: 20, verticalInset: 16, lineSpacing: 3, headingSpacing: 8, imageCornerRadius: 6)
}

@MainActor
final class EditorHarness {
    let store = DirectoryFileStore()
    let editor: CueEditorView
    let window: NSWindow
    var textView: CueTextView { editor.textView }

    init(width: CGFloat = 720, height: CGFloat = 640, theme: CueEditorTheme = .test) {
        _ = NSApplication.shared
        editor = CueEditorView(files: store, theme: theme)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        editor.frame = window.contentView!.bounds
        editor.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(editor)
        window.makeFirstResponder(textView)
    }

    func layout() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// 让出主线程一小段：分片布局、异步缩略图都排在主队列里，同步测试体里推进不了它们。
    func pump(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
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

    func renderedCenterColor(of rect: CGRect) -> NSColor? {
        let rep = textView.bitmapImageRepForCachingDisplay(in: rect)!
        textView.cacheDisplay(in: rect, to: rep)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cue-editor-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func setCaret(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }
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
