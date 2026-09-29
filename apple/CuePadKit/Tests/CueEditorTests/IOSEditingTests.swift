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
    private let split = CueFormat.splitMarker

    @Test("存储格式往返：文字、图片、分隔线；旧角色标记归一化；缺失图片保留引用")
    func roundTrip() throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 40, height: 30))
        let stored = "前\n![](cuepad://img/\(id))\n\(split)\n后 ![](cuepad://img/00000000deadbeef)"
        h.load(stored)
        #expect(h.stored == stored)
        h.load("a\n---ask---\nb")
        #expect(h.stored == "a\n\(split)\nb")
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

    @Test("粘贴文本按存储格式解析：分隔线行与图片标记还原成控件")
    func pasteText() async {
        let h = EditorHarness()
        let item = await transform(NSItemProvider(object: "a\n\(split)\nb" as NSString), in: h)
        #expect(attachments(in: item.result).first is CueDividerAttachment)
        #expect(item.result?.string == "a\n\u{FFFC}\nb")
    }

    @Test("图片入库失败：报告错误、不插入")
    func importFailure() async throws {
        let h = EditorHarness()
        let failing = CueTextView(imageStore: FailingStore())
        h.window.addSubview(failing)
        h.window.layoutIfNeeded()
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

    @Test("图片宽度自适应：不超过行宽、保持比例，窗口变窄后跟随")
    func widthAdapts() throws {
        let h = EditorHarness(width: 390)
        let id = try h.store.store(makePNG(width: 1600, height: 1000))
        h.load("![](cuepad://img/\(id))")
        let wide = try #require(h.imageLineFrames().first)
        let container = h.textView.textContainer.size.width - 2 * h.textView.textContainer.lineFragmentPadding
        #expect(wide.width <= container + 0.5)
        #expect(abs(wide.width / wide.height - 1.6) < 0.02)

        h.window.frame.size.width = 300
        h.textView.frame.size.width = 300
        h.layout()
        let narrow = try #require(h.imageLineFrames().first)
        #expect(narrow.width < wide.width)
    }

    @Test("图片像素在进入视口后显示出来")
    func rendersPixels() async throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 800, height: 400, color: UIColor(red: 1, green: 0, blue: 0, alpha: 1)))
        h.load("![](cuepad://img/\(id))")
        let frame = try #require(h.imageLineFrames().first)
        #expect(await h.wait {
            guard let color = h.renderedCenterColor(of: frame) else { return false }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: nil)
            return r > 0.8 && g < 0.4 && b < 0.3
        })
    }

    @Test("缩略图按需解码：视口外的图片不被读取")
    func lazyDecode() async throws {
        let h = EditorHarness(height: 400)
        var stored = ""
        for i in 0..<20 {
            let id = try h.store.store(makePNG(width: 800, height: 800, color: UIColor(hue: CGFloat(i) / 20, saturation: 0.7, brightness: 0.9, alpha: 1)))
            stored += "第 \(i) 张\n![](cuepad://img/\(id))\n"
        }
        let before = ImageLoading.decodeCount
        h.load(stored)
        #expect(await h.wait { ImageLoading.decodeCount > before })
        await h.pump(0.3)
        #expect(ImageLoading.decodeCount - before < 20)
    }
}
#endif
