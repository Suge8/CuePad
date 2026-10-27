import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

/// 分享扩展 → 主 App 的数据通路：扩展只写共享容器里的待入库目录，主 App 入库成卡片。
struct CaptureTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var queue: URL { services.location.captureDirectory }
    let png = pngData()

    private func hash(of data: Data) throws -> String { try services.store.files.store(data) }

    /// 扩展拷到临时目录的那份。
    private func shared(_ data: Data, named name: String) throws -> ShareContent.File {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
        try data.write(to: url)
        return ShareContent.File(url: url, name: name)
    }

    @Test func 文字网址图片与文件按顺序存成卡片_放进所选项目() async throws {
        let project = try await services.store.createProject(name: "P", color: "#123456")
        let pdf = Data("%PDF-1.4".utf8)
        let content = ShareContent(
            text: "读一下这个", urls: [URL(string: "https://a.example/x")!, URL(string: "https://b.example")!],
            files: [try shared(png, named: "截图.png"), try shared(pdf, named: "报价 [终版].pdf")])
        try CaptureQueue.enqueue(content, project: project.id, into: queue)

        await services.drainCaptures()

        let cards = try await services.store.cards(in: project.id)
        #expect(cards.count == 1)
        let body = try #require(cards.first?.body)
        let pdfKey = try #require(CueFormat.attachmentKeys(in: body).last)
        #expect(pdfKey.hasSuffix(".pdf"))
        let expected = "读一下这个\n\nhttps://a.example/x\nhttps://b.example\n\n![](cuepad://file/\(try hash(of: png)))\n[报价 (终版).pdf](cuepad://file/\(pdfKey))"
        #expect(cards.first?.body == expected)
        #expect(CaptureQueue.pending(in: queue).isEmpty, "入库后条目应删除")
    }

    @Test func 所选项目已删除时进默认项目() async throws {
        let gone = try await services.store.createProject(name: "Gone", color: "#000000")
        try await services.store.trashProject(gone.id)
        try CaptureQueue.enqueue(ShareContent(text: "b"), project: gone.id, into: queue)
        try CaptureQueue.enqueue(ShareContent(text: "c"), project: UUID(), into: queue)

        await services.drainCaptures()

        #expect(Set(try await services.store.cards(in: Project.defaultID).map(\.body)) == ["b", "c"])
    }

    /// 扩展还没写完的条目跳过、不删；入库失败的条目（这里是图读不出来）保留并报告；都不挡其他条目。
    @Test func 没写完与入库失败的条目都留着_不影响其他条目() async throws {
        let unfinished = queue.appending(path: "half-written", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try png.write(to: unfinished.appending(path: "image-1.png"))
        try CaptureQueue.enqueue(
            ShareContent(text: "坏图", files: [try shared(png, named: "坏图.png")]), project: Project.defaultID, into: queue,
            now: Date(timeIntervalSince1970: 1))
        let unreadable = try #require(CaptureQueue.pending(in: queue).first?.files().first?.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        try CaptureQueue.enqueue(ShareContent(text: "好的"), project: Project.defaultID, into: queue, now: Date(timeIntervalSince1970: 2))

        await services.drainCaptures()

        #expect(try await services.store.cards(in: Project.defaultID).map(\.body) == ["好的"])
        #expect(CaptureQueue.pending(in: queue).map(\.capture.text) == ["坏图"])
        #expect(FileManager.default.fileExists(atPath: unfinished.path))
        #expect(services.startupIssues.count == 1)
    }

    @Test func 收到扩展的通知后自动入库() async throws {
        services.startCaptureIngest()
        defer { services.cancelBackgroundWork() }
        try CaptureQueue.enqueue(ShareContent(text: "来自扩展"), project: Project.defaultID, into: queue)

        DarwinNotifications.post(CaptureQueue.notification)

        let bodies = try await eventually(services.store, { try $0.cards(in: Project.defaultID).map(\.body) }) { !$0.isEmpty }
        #expect(bodies == ["来自扩展"])
    }
}
