import CueStore
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

    @Test func 文字网址图片按顺序存成卡片_放进所选项目() async throws {
        let project = try await services.store.createProject(name: "P", color: "#123456")
        let content = ShareContent(
            text: "读一下这个", urls: [URL(string: "https://a.example/x")!, URL(string: "https://b.example")!],
            images: [.init(data: png, fileExtension: "png")])
        try CaptureQueue.enqueue(content, project: project.id, into: queue)

        await services.drainCaptures()

        let cards = try await services.store.cards(in: project.id)
        #expect(cards.count == 1)
        let expected = "读一下这个\n\nhttps://a.example/x\nhttps://b.example\n\n![](cuepad://img/\(try hash(of: png)))"
        #expect(cards.first?.body == expected)
        #expect(CaptureQueue.pending(in: queue).isEmpty, "入库后条目应删除")
    }

    @Test func 没选项目或项目已删除时进未分类() async throws {
        let gone = try await services.store.createProject(name: "Gone", color: "#000000")
        try await services.store.trashProject(gone.id)
        try CaptureQueue.enqueue(ShareContent(text: "a"), project: nil, into: queue)
        try CaptureQueue.enqueue(ShareContent(text: "b"), project: gone.id, into: queue)
        try CaptureQueue.enqueue(ShareContent(text: "c"), project: UUID(), into: queue)

        await services.drainCaptures()

        #expect(Set(try await services.store.cards(in: nil).map(\.body)) == ["a", "b", "c"])
    }

    @Test func 没写完的条目被跳过_不删除() async throws {
        let unfinished = queue.appending(path: "half-written", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try png.write(to: unfinished.appending(path: "image-1.png"))

        await services.drainCaptures()

        #expect(try await services.store.cards(in: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: unfinished.path))
    }

    @Test func 入库失败的条目保留并报告_不影响其他条目() async throws {
        try CaptureQueue.enqueue(
            ShareContent(text: "坏图", images: [.init(data: Data("not an image".utf8), fileExtension: "png")]),
            project: nil, into: queue, now: Date(timeIntervalSince1970: 1))
        try CaptureQueue.enqueue(ShareContent(text: "好的"), project: nil, into: queue, now: Date(timeIntervalSince1970: 2))

        await services.drainCaptures()

        #expect(try await services.store.cards(in: nil).map(\.body) == ["好的"])
        #expect(CaptureQueue.pending(in: queue).map(\.capture.text) == ["坏图"])
        #expect(services.startupIssues.count == 1)
    }

    @Test func 收到扩展的通知后自动入库() async throws {
        services.startCaptureIngest()
        defer { services.cancelBackgroundWork() }
        try CaptureQueue.enqueue(ShareContent(text: "来自扩展"), project: nil, into: queue)

        DarwinNotifications.post(CaptureQueue.notification)

        let bodies = try await eventually(services.store, { try $0.cards(in: nil).map(\.body) }) { !$0.isEmpty }
        #expect(bodies == ["来自扩展"])
    }
}
