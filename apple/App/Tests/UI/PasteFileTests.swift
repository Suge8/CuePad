#if os(iOS)
import CueEditor
import CueStore
import Foundation
import Testing
import UIKit
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct PasteFileTests {
    let app = TestApp()

    @Test func 回复框粘贴文件App里复制的PDF_交给附件条_文字区不进字() async throws {
        let files = app.services.store.files
        let pdf = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "季度复盘.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 季度复盘".utf8).write(to: pdf)
        let pasteboard = app.pasteboard
        // 刚写进新建的剪贴板就去读，条目的内容取不出来（种类读得到）：等它报"变了"再粘
        let written = NotificationCenter.default.notifications(named: UIPasteboard.changedNotification)
        pasteboard.itemProviders = [try #require(NSItemProvider(contentsOf: pdf))]
        for await _ in written { break }

        let field = GrowingTextView(pasteboard: pasteboard)
        var incoming: [IncomingFile] = []
        field.files = { incoming += $0 }
        #expect(field.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        field.paste(nil)

        var names: [String] = []
        for file in incoming { names.append(try await DraftFile.store(file, in: files).name) }
        #expect(names == ["季度复盘.pdf"])
        #expect(field.text.isEmpty)
    }
}
#endif
