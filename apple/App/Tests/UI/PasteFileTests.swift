#if os(iOS)
import CueEditor
import CueStore
import Foundation
import Testing
import UIKit
@testable import CuePad

/// 手机回复框粘贴：剪贴板里的任意文件（文件 App 里复制的 PDF）收进附件条，与卡片编辑器的粘贴同一条规则（`PastedItem`）；
/// 发出去时正文里是这份文件。
@MainActor
struct PasteFileTests {
    let app = TestApp()

    @Test func 回复框粘贴文件App里复制的PDF_收进附件条随话发出() async throws {
        try await PiStateRecorder(store: app.services.store, hostID: "mac-b").update(sessionID: "atlas", state: .settled, title: "atlas")
        let session = try #require(try await app.services.store.allPiSessionStates().first)
        let pdf = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "季度复盘.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 季度复盘".utf8).write(to: pdf)
        app.pasteboard.itemProviders = [try #require(NSItemProvider(contentsOf: pdf))]

        let field = GrowingTextView()
        field.pasteboard = app.pasteboard
        let pasted = AsyncStream<[IncomingFile]>.makeStream()
        field.files = { pasted.continuation.yield($0) }
        #expect(field.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        field.paste(nil)
        var incoming: [IncomingFile] = []
        for await files in pasted.stream { incoming = files; break }
        var draft = ComposerDraft(text: "看看这份")
        for file in incoming { draft.files.append(try await DraftFile.store(file, in: app.services.store.files)) }

        let request = try await Workspace(services: app.services).said(draft, to: session, mode: .send)
        let key = try #require(draft.files.first?.key)
        #expect(draft.files.map(\.name) == ["季度复盘.pdf"] && key.hasSuffix(".pdf"))
        #expect(request.content.contains("[季度复盘.pdf](cuepad://file/\(key))"))
        #expect(field.text.isEmpty)
    }
}
#endif
