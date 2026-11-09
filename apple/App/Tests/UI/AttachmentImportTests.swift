import CueStore
import CueText
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 回复框选了附件、还在存（大文件要读一遍算哈希）时就发送：附件随这句发出，不丢，也不落进下一条草稿。
struct AttachmentImportTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 附件还在存时发送_随这句发出_下一条草稿是空的() async throws {
        let workspace = Workspace(services: app.services)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data(repeating: 7, count: 8_000_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = ComposerDraft(text: "看这个")
        let box = Binding(get: { draft }, set: { draft = $0 })

        workspace.importFiles([.file(url)], into: box)
        #expect(!draft.importing.isEmpty && draft.files.isEmpty, "附件还在存")
        await workspace.speak(to: .cue, from: box) { $0.stored }.value

        let said = try #require(try await store.cueMessages().last { $0.author == .known(.you) })
        let key = try #require(CueFormat.attachmentKeys(in: said.text).first, "发出的话带着附件：\(said.text)")
        #expect(said.text.hasPrefix("看这个") && store.files.fileURL(for: key) != nil)
        await quietPeriod(.milliseconds(300))
        #expect(draft.files.isEmpty && draft.importing.isEmpty, "下一条草稿不带它")
    }

    @Test func 只选了附件还在存就发送_也发得出去() async throws {
        let workspace = Workspace(services: app.services)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data(repeating: 1, count: 1_000_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = ComposerDraft()
        let box = Binding(get: { draft }, set: { draft = $0 })

        workspace.importFiles([.file(url)], into: box)
        #expect(!draft.isEmpty(accepting: .files), "存的途中也算有东西可发")
        await workspace.speak(to: .cue, from: box) { $0.stored }.value

        let said = try #require(try await store.cueMessages().last { $0.author == .known(.you) })
        #expect(!CueFormat.attachmentKeys(in: said.text).isEmpty)
    }

    @Test func 存好了再发_附件在草稿里照常带上() async throws {
        let workspace = Workspace(services: app.services)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data(repeating: 2, count: 1000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = ComposerDraft(text: "看这个")
        let box = Binding(get: { draft }, set: { draft = $0 })

        workspace.importFiles([.file(url)], into: box)
        try await eventually("附件接进了草稿") { draft.files.count == 1 && draft.importing.isEmpty }
        await workspace.speak(to: .cue, from: box) { $0.stored }.value

        let said = try #require(try await store.cueMessages().last { $0.author == .known(.you) })
        #expect(CueFormat.attachmentKeys(in: said.text).count == 1 && draft.files.isEmpty)
    }

    /// 先发带慢附件的 A、紧接着发 B：库里的先后仍是 A、B。
    @Test func 带慢附件的先发_后发的不抢在前面落库() async throws {
        let workspace = Workspace(services: app.services)
        DebugHooks.importDelaySeconds = 1
        defer { DebugHooks.importDelaySeconds = 0 }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data(repeating: 2, count: 1000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = ComposerDraft(text: "A")
        let box = Binding(get: { draft }, set: { draft = $0 })

        workspace.importFiles([.file(url)], into: box)
        let first = workspace.speak(to: .cue, from: box) { $0.stored }
        draft.text = "B"
        let second = workspace.speak(to: .cue, from: box) { $0.stored }
        await first.value
        await second.value

        let said = try await store.cueMessages().filter { $0.author == .known(.you) }.map { String($0.text.prefix(1)) }
        #expect(said == ["A", "B"], "落库顺序：\(said)")
    }

    /// 只选了存不进去的附件就记下：不建空灵感。
    @Test func 附件都没存成_随手记不建空灵感() async throws {
        let workspace = Workspace(services: app.services)
        let before = try await store.cards(in: Project.defaultID).count
        var draft = ComposerDraft()
        let box = Binding(get: { draft }, set: { draft = $0 })

        workspace.importFiles([.file(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).txt"))], into: box)
        await workspace.note(from: box)?.value

        #expect(try await store.cards(in: Project.defaultID).count == before)
    }
}
