#if canImport(AppKit)
import AppKit
import CueText
import Testing
@testable import CueEditor

@MainActor
@Suite("内联图片")
struct ImageTests {
    @Test("粘贴 PNG：以附件显示，存储只留引用，图片经注入的库存入，编辑通知带新正文")
    func pastePNG() throws {
        let h = EditorHarness()
        h.load("前文后文")
        h.setCaret(2)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }
        let png = makePNG()
        let pasteboard = h.privatePasteboard()
        pasteboard.setData(png, forType: .png)

        #expect(h.textView.readSelection(from: pasteboard, type: .png))

        let imageID = try #require(CueFormat.parse(h.stored).compactMap { if case .image(let id) = $0 { id } else { nil } }.first)
        #expect(h.stored == "前文![](cuepad://img/\(imageID))后文")
        #expect(h.store.storedData == [png])
        #expect(notified == [h.stored])
    }

    @Test("剪贴板只有 TIFF 时（如浏览器复制的图）转成 PNG 入库")
    func pasteTIFF() throws {
        let h = EditorHarness()
        let pasteboard = h.privatePasteboard()
        pasteboard.setData(NSBitmapImageRep(data: makePNG(width: 40, height: 30))!.tiffRepresentation!, forType: .tiff)

        #expect(h.textView.readSelection(from: pasteboard, type: .tiff))

        let stored = try #require(h.store.storedData.first)
        #expect(stored.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(h.stored.hasPrefix("![](cuepad://img/"))
    }

    @Test("拖入图片文件：按落点插入")
    func dropFile() throws {
        let h = EditorHarness()
        h.load("第一行文字\n第二行文字")
        let file = h.store.directory.appendingPathComponent("dropped.png")
        try makePNG(width: 400, height: 200).write(to: file)
        let pasteboard = h.privatePasteboard()
        pasteboard.writeObjects([file as NSURL])
        // 第二行行首附近（标题行更高，位置从布局里取）
        var secondLine = CGRect.zero
        h.textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            if (fragment.textElement as? NSTextParagraph)?.attributedString.string == "第二行文字" {
                secondLine = fragment.layoutFragmentFrame.offsetBy(dx: h.textView.textContainerOrigin.x, dy: h.textView.textContainerOrigin.y)
            }
            return true
        }
        let point = h.textView.convert(NSPoint(x: 8, y: secondLine.midY), to: nil)

        let drag = FakeDrag(pasteboard: pasteboard, location: point, window: h.window)
        #expect(h.textView.draggingEntered(drag) == .copy)
        #expect(h.textView.performDragOperation(drag))

        let tokens = CueFormat.parse(h.stored)
        let imageIndex = try #require(tokens.firstIndex { if case .image = $0 { true } else { false } })
        // 图片落在第二行行首附近，而不是文末
        let before = CueFormat.serialize(Array(tokens[..<imageIndex]))
        #expect(before.hasPrefix("第一行文字\n"))
        #expect(!before.contains("第二行文字"))
        #expect(h.stored.hasSuffix("第二行文字"))
    }

    @Test("单次粘贴可撤销、可重做")
    func undoRedo() {
        let h = EditorHarness()
        h.load("文字")
        h.textView.undoManager?.removeAllActions()
        let pasteboard = h.privatePasteboard()
        pasteboard.setData(makePNG(width: 40, height: 30), forType: .png)
        _ = h.textView.readSelection(from: pasteboard, type: .png)
        let pasted = h.stored

        h.textView.undoManager?.undo()
        #expect(h.stored == "文字")
        h.textView.undoManager?.redo()
        #expect(h.stored == pasted)
    }

    @Test("图片后继续键入：新字符是普通文字，不带附件")
    func typingAfterImage() {
        let h = EditorHarness()
        let pasteboard = h.privatePasteboard()
        pasteboard.setData(makePNG(width: 40, height: 30), forType: .png)
        _ = h.textView.readSelection(from: pasteboard, type: .png)
        h.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.stored.hasSuffix(")x"))
        #expect(CueFormat.parse(h.stored).filter { if case .image = $0 { true } else { false } }.count == 1)
    }

    @Test("编辑器内复制输出存储格式，粘回去还原成图片")
    func copyRoundTrip() throws {
        let h = EditorHarness()
        let pasteboard = h.privatePasteboard()
        pasteboard.setData(makePNG(width: 40, height: 30), forType: .png)
        h.load("甲乙")
        h.setCaret(1)
        _ = h.textView.readSelection(from: pasteboard, type: .png)
        let original = h.stored
        h.textView.setSelectedRange(NSRange(location: 0, length: h.textView.textStorage!.length))

        let copied = h.privatePasteboard()
        #expect(h.textView.writeSelection(to: copied, types: [.string]))
        #expect(copied.string(forType: .string) == original)

        let other = EditorHarness()
        _ = other.store  // 独立的库：图片 id 在库里不存在，也要原样往返
        #expect(other.textView.readSelection(from: copied, type: .string))
        #expect(other.stored == original)
    }

    @Test("图片文件缺失时存储引用保持不变")
    func missingImage() {
        let h = EditorHarness()
        let stored = "前\n![](cuepad://img/00000000deadbeef)\n后"
        h.load(stored)
        #expect(h.stored == stored)
        #expect(h.imageLineFrames().count == 1)
    }

    @Test("图片宽度自适应：不超过行宽、保持比例，窗口缩放后跟随")
    func widthAdapts() throws {
        let h = EditorHarness(width: 720)
        let id = try h.store.store(makePNG(width: 1600, height: 1000))
        h.load("![](cuepad://img/\(id))")
        let wide = try #require(h.imageLineFrames().first)
        let container = h.textView.textContainer!.size.width - 2 * h.textView.textContainer!.lineFragmentPadding
        #expect(wide.width <= container + 0.5)
        #expect(abs(wide.width / wide.height - 1.6) < 0.02)

        h.window.setContentSize(NSSize(width: 420, height: 640))
        h.layout()
        let narrow = try #require(h.imageLineFrames().first)
        #expect(narrow.width < wide.width)
        #expect(narrow.width <= h.textView.bounds.width)
    }

    @Test("图片像素在进入视口后显示出来，解码不阻塞加载")
    func rendersPixels() async throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 800, height: 400, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        h.load("![](cuepad://img/\(id))")
        let frame = try #require(h.imageLineFrames().first)
        #expect(await h.wait {
            guard let color = h.renderedCenterColor(of: frame) else { return false }
            return color.redComponent > 0.8 && color.greenComponent < 0.4 && color.blueComponent < 0.3  // 红色主导（色彩管理会让数值略偏）
        })
    }

    @Test("缩略图按需解码：视口外的图片不被读取")
    func lazyDecode() async throws {
        let h = EditorHarness(height: 400)
        var stored = ""
        var urls: [URL] = []
        for i in 0..<20 {
            let id = try h.store.store(makePNG(width: 800, height: 800, seed: i + 100))
            urls.append(try #require(h.store.fileURL(for: id)))
            stored += "第 \(i) 张\n![](cuepad://img/\(id))\n"
        }
        func decoded(_ url: URL) -> Bool { Thumbnails.cached(at: url, maxPixel: ImageLoading.maxThumbnailPixel) != nil }
        h.load(stored)
        h.layout()
        #expect(await h.wait { decoded(urls[0]) })
        await h.pump(0.3)
        #expect(!decoded(urls[19]))
    }
}

#endif
