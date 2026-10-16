#if canImport(UIKit)
import CueText
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CueEditor

private struct DiskFull: Error {}

private final class FailingStore: CueImageStore {
    func store(_ data: Data) throws -> String { throw DiskFull() }
    func store(fileAt url: URL) throws -> String { throw DiskFull() }
    func fileURL(for id: String) -> URL? { nil }
}

/// 把一个条目交给粘贴/拖入委托，等它给出结果（UIKit 的粘贴与拖入都走这条路）。
@MainActor
private func transform(_ provider: NSItemProvider, in h: EditorHarness) async -> FakePasteItem {
    let item = FakePasteItem(provider)
    h.textView.pasteDelegate?.textPasteConfigurationSupporting?(h.textView, transform: item)
    _ = await h.wait { item.resolved }
    return item
}

private func attachments(in string: NSAttributedString?) -> [NSTextAttachment] {
    var found: [NSTextAttachment] = []
    string?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string?.length ?? 0)) { value, _, _ in
        if let attachment = value as? NSTextAttachment { found.append(attachment) }
    }
    return found
}

@MainActor
@Suite("iOS 存储与图片")
struct IOSEditingTests {
    @Test("存储格式往返：文字（含分割线 ---）、图片；缺失图片保留引用")
    func roundTrip() throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 40, height: 30))
        let stored = "前\n![](cuepad://img/\(id))\n---\n后 ![](cuepad://img/00000000deadbeef)"
        h.load(stored)
        #expect(h.stored == stored)
    }

    @Test("粘贴/拖入图片文件：委托给出带图片附件的结果，图片经注入的库存入")
    func pasteImageFile() async throws {
        let h = EditorHarness()
        let png = makePNG(width: 60, height: 40)
        let file = h.store.directory.appendingPathComponent("dropped.png")
        try png.write(to: file)

        let item = await transform(NSItemProvider(contentsOf: file)!, in: h)

        let attachment = try #require(attachments(in: item.result).first as? CueImageAttachment)
        #expect(h.store.storedData == [png])
        #expect(h.store.fileURL(for: attachment.imageID) != nil)
        #expect(attachments(in: item.result).count == 1)
    }

    @Test("剪贴板里的图片对象（相册、截图）同样入库")
    func pasteImageObject() async throws {
        let h = EditorHarness()
        let image = try #require(UIImage(data: makePNG(width: 60, height: 40)))

        let item = await transform(NSItemProvider(object: image), in: h)

        #expect(attachments(in: item.result).first is CueImageAttachment)
        #expect(h.store.storedData.count == 1)
    }

    @Test("粘贴文本按存储格式解析：图片标记还原成图片，其余（含分割线）原样")
    func pasteText() async throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 40, height: 30))
        let item = await transform(NSItemProvider(object: "a\n---\n![](cuepad://img/\(id))" as NSString), in: h)
        #expect(attachments(in: item.result).first is CueImageAttachment)
        #expect(item.result?.string == "a\n---\n\u{FFFC}")
    }

    @Test("图片入库失败：报告错误、不插入")
    func importFailure() async throws {
        let h = EditorHarness()
        let failing = CueTextView(imageStore: FailingStore(), theme: .test)
        h.root.addSubview(failing)
        h.root.layoutIfNeeded()
        var errors: [any Error] = []
        failing.onError = { errors.append($0) }
        let item = FakePasteItem(NSItemProvider(object: try #require(UIImage(data: makePNG(width: 20, height: 20)))))

        failing.pasteDelegate?.textPasteConfigurationSupporting?(failing, transform: item)
        #expect(await h.wait { item.resolved })

        #expect(item.result == nil && !item.usedDefault)
        #expect(errors.count == 1 && errors.first is DiskFull)
    }

    @Test("insertImage：光标处插入图片引用并通知，可撤销、可重做；后续键入是普通文字")
    func insertImage() throws {
        let h = EditorHarness()
        h.load("前文后文")
        h.setCaret(2)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }

        h.textView.insertImage(data: makePNG(width: 40, height: 30))

        let id = try #require(CueFormat.parse(h.stored).compactMap { if case .image(let id) = $0 { id } else { nil } }.first)
        #expect(h.stored == "前文![](cuepad://img/\(id))后文")
        #expect(notified == [h.stored])
        let inserted = h.stored

        h.textView.undoManager?.undo()
        #expect(h.stored == "前文后文")
        h.textView.undoManager?.redo()
        #expect(h.stored == inserted)

        h.textView.insertText("x")
        #expect(h.stored == "前文![](cuepad://img/\(id))x后文")
    }

    @Test("编辑器内复制/剪切输出存储格式，粘回去还原成图片")
    func copyAndCut() async throws {
        let h = EditorHarness()
        h.textView.pasteboard = h.privatePasteboard()
        h.load("甲乙")
        h.setCaret(1)
        h.textView.insertImage(data: makePNG(width: 40, height: 30))
        let original = h.stored
        h.textView.selectedRange = NSRange(location: 0, length: h.textView.textStorage.length)

        h.textView.copy(nil)
        #expect(h.textView.pasteboard.string == original)
        #expect(h.stored == original)

        let item = await transform(NSItemProvider(object: try #require(h.textView.pasteboard.string) as NSString), in: h)
        #expect((attachments(in: item.result).first as? CueImageAttachment)?.imageID != nil)

        h.textView.pasteboard.string = ""
        h.textView.cut(nil)
        #expect(h.textView.pasteboard.string == original)
        #expect(h.stored == "")
        h.textView.undoManager?.undo()
        #expect(h.stored == original)
    }

}
#endif
