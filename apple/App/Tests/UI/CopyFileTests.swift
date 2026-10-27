#if os(macOS)
import AppKit
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

/// Mac 上复制带文件的灵感：富文本（RTFD）按原顺序带上图片与文件附件，粘进备忘录、邮件里能拿到文件；
/// 纯文本那份写文件名；还没到本机的文件只写文件名，照样复制成功。
@MainActor
struct CopyFileTests {
    let app = TestApp()

    @Test func 复制带文件的灵感_富文本带上文件_纯文本写文件名() async throws {
        let files = app.services.store.files
        let pdfData = Data("%PDF-1.4 季度复盘".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "季度复盘.pdf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdfData.write(to: source)
        let pdf = try files.store(fileAt: source)
        let image = try files.store(pngData())
        let away = String(repeating: "b", count: 64) + ".mov"
        let card = try await app.services.store.createCard(
            body: "看材料\n\(CueFormat.fileMarkup(key: pdf, name: "季度复盘.pdf"))\n\(CueFormat.imageMarkup(key: image))\n\(CueFormat.fileMarkup(key: away, name: "录屏.mov"))")
        app.pasteboard.clearContents()

        let workspace = Workspace(services: app.services)
        workspace.copy(card.body)

        #expect(app.pasteboard.string(forType: .string) == "看材料\n季度复盘.pdf\n\n录屏.mov")
        let rtfd = try #require(app.pasteboard.data(forType: .rtfd))
        let pasted = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var wrappers: [FileWrapper] = []
        pasted.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pasted.length)) { value, _, _ in
            if let wrapper = (value as? NSTextAttachment)?.fileWrapper { wrappers.append(wrapper) }
        }
        #expect(wrappers.count == 2)
        #expect(wrappers.first?.preferredFilename == "季度复盘.pdf" && wrappers.first?.regularFileContents == pdfData)
        #expect(wrappers.last?.preferredFilename?.hasSuffix(".png") == true)
        #expect(pasted.string.contains("录屏.mov"))
    }
}
#endif
