import AppKit
import Testing

@testable import CueDispatch

/// 用私有命名剪贴板，不影响用户的通用剪贴板。
@Suite struct PasteboardTests {
    private static let png: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    @Test func 图文写成按原顺序含图的RTFD并附纯文字兜底() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let payload = Payload([.text("前"), .image(Self.png), .text("后")])

        try PasteboardWriter(board).write(payload)

        // 单条目：图形应用取 RTFD，终端取 string；不再并列放 png/tiff，否则 TextEdit 只取图片
        let types = Set(board.pasteboardItems?.first?.types ?? [])
        #expect(board.pasteboardItems?.count == 1)
        #expect(types == [.rtfd, .string])
        #expect(board.string(forType: .string) == "前后")
        let rtfd = try #require(board.data(forType: .rtfd))
        let document = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        #expect(document.string == "前\u{FFFC}后")
        let attachment = document.attribute(.attachment, at: 1, effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.fileWrapper?.regularFileContents == Self.png)
    }

    @Test func 多张图片保持各自位置() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PasteboardWriter(board).write(Payload([.image(Self.png), .text("中"), .image(Self.png)]))
        let rtfd = try #require(board.data(forType: .rtfd))
        let document = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        #expect(document.string == "\u{FFFC}中\u{FFFC}")
    }

    @Test func 纯文字只写string() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PasteboardWriter(board).write(Payload(text: "only text"))
        #expect(Set(board.pasteboardItems?.first?.types ?? []) == [.string])
        #expect(board.string(forType: .string) == "only text")
    }

    @Test func 非图片字节拒绝写入() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(throws: DispatchError.clipboardWriteFailed) {
            try PasteboardWriter(board).write(Payload([.text("x"), .image(Data("not png".utf8))]))
        }
    }
}
