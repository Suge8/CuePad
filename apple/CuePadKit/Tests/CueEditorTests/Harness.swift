import AppKit
import CryptoKit
import CueEditor
import CueText

/// 目录里放真实文件的内存图片库：CueEditor 只经 `CueImageStore` 协议读写图片。
final class DirectoryImageStore: CueImageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: URL] = [:]
    private(set) var storedData: [Data] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cue-editor-tests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(_ data: Data) throws -> String {
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(id)
        try data.write(to: url)
        lock.withLock { files[id] = url; storedData.append(data) }
        return id
    }

    func store(fileAt url: URL) throws -> String { try store(Data(contentsOf: url)) }

    func fileURL(for id: String) -> URL? { lock.withLock { files[id] } }
}

func makePNG(width: Int = 1600, height: Int = 1000, seed: Int = 0) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(hue: CGFloat(seed % 20) / 20, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
final class EditorHarness {
    let store = DirectoryImageStore()
    let editor: CueEditorView
    let window: NSWindow
    var textView: CueTextView { editor.textView }

    init(width: CGFloat = 720, height: CGFloat = 640, theme: CueEditorTheme = .neutral) {
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
        pump(0.05)
    }

    /// 让主循环运转一小段：TextKit 视口布局与异步缩略图都在主循环里推进。
    func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 条件等待：主循环运转到条件成立，超时视为失败。
    func wait(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            pump(0.02)
        }
        return true
    }

    func subviews<T: NSView>(of type: T.Type) -> [T] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(textView).compactMap { $0 as? T }
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
