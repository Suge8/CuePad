#if canImport(UIKit)
import CueText
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CueEditor

/// 拖出选区时 UIKit 交给委托的请求；只有 dragRange 会被读取。
private final class FakeDragRequest: NSObject, UITextDragRequest {
    let dragRange: UITextRange
    var suggestedItems: [UIDragItem] { [] }
    var existingItems: [UIDragItem] { [] }
    var isSelected: Bool { true }
    var dragSession: any UIDragSession { fatalError("委托不读取拖拽会话") }
    init(_ range: UITextRange) { dragRange = range }
}

@MainActor
@Suite("iOS 与 Mac 对齐")
struct IOSAlignmentTests {
    @Test("拖出选区输出存储格式（与 Mac 一致），图片不会被归档成富文本")
    func dragOutStoredFormat() async throws {
        let h = EditorHarness()
        h.load("甲乙")
        h.setCaret(1)
        h.textView.insertImage(data: makePNG(width: 40, height: 30))
        let original = h.stored
        h.textView.selectedRange = NSRange(location: 0, length: h.textView.textStorage.length)
        let range = try #require(h.textView.selectedTextRange)

        let items = try #require(h.textView.textDragDelegate?.textDraggableView?(h.textView, itemsForDrag: FakeDragRequest(range)))

        let provider = try #require(items.first?.itemProvider)
        #expect(items.count == 1)
        let text: String? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in continuation.resume(returning: object as? String) }
        }
        #expect(text == original)
    }
}
#endif
