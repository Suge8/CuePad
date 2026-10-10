import CueStore
import Foundation
import Testing
@testable import CuePad

/// 分享扩展 → 主 App 的数据通路：扩展只写共享容器里的待入库目录，主 App 入库成卡片。
@MainActor
struct CaptureTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var inbox: URL { services.location.captureDirectory }
    let png = pngData()

    private func hash(of data: Data) throws -> String { try services.store.files.store(data) }

    @Test func 文字网址图片按顺序存成卡片_放进所选项目() async throws {
        let project = try await services.store.createProject(name: "P", color: "#123456")
        let content = ShareContent(
            text: "读一下这个", urls: [URL(string: "https://a.example/x")!, URL(string: "https://b.example")!],
            images: [.init(data: png, fileExtension: "png")])
        try CaptureInbox.enqueue(content, project: project.id, into: inbox)

        await services.drainCaptures()

        let cards = try await services.store.cards(in: project.id)
        #expect(cards.count == 1)
        let expected = "读一下这个\n\nhttps://a.example/x\nhttps://b.example\n\n![](cuepad://img/\(try hash(of: png)))"
        #expect(cards.first?.body == expected)
        #expect(CaptureInbox.pending(in: inbox).isEmpty, "入库后条目应删除")
    }

    @Test func 没选项目或项目已删除时进收件箱() async throws {
        let gone = try await services.store.createProject(name: "Gone", color: "#000000")
        try await services.store.trashProject(gone.id)
        try CaptureInbox.enqueue(ShareContent(text: "a"), project: nil, into: inbox)
        try CaptureInbox.enqueue(ShareContent(text: "b"), project: gone.id, into: inbox)
        try CaptureInbox.enqueue(ShareContent(text: "c"), project: UUID(), into: inbox)

        await services.drainCaptures()

        #expect(Set(try await services.store.cards(in: nil).map(\.body)) == ["a", "b", "c"])
    }

    @Test func 没写完的条目被跳过_不删除() async throws {
        let unfinished = inbox.appending(path: "half-written", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try png.write(to: unfinished.appending(path: "image-1.png"))

        await services.drainCaptures()

        #expect(try await services.store.cards(in: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: unfinished.path))
    }

    @Test func 入库失败的条目保留并报告_不影响其他条目() async throws {
        try CaptureInbox.enqueue(
            ShareContent(text: "坏图", images: [.init(data: Data("not an image".utf8), fileExtension: "png")]),
            project: nil, into: inbox, now: Date(timeIntervalSince1970: 1))
        try CaptureInbox.enqueue(ShareContent(text: "好的"), project: nil, into: inbox, now: Date(timeIntervalSince1970: 2))

        await services.drainCaptures()

        #expect(try await services.store.cards(in: nil).map(\.body) == ["好的"])
        #expect(CaptureInbox.pending(in: inbox).map(\.capture.text) == ["坏图"])
        #expect(services.startupIssues.count == 1)
    }

    @Test func 收到扩展的通知后自动入库() async throws {
        services.startCaptureIngest()
        defer { services.cancelBackgroundWork() }
        try CaptureInbox.enqueue(ShareContent(text: "来自扩展"), project: nil, into: inbox)

        DarwinNotifications.post(CaptureInbox.notification)

        var bodies: [String] = []
        for _ in 0..<300 where bodies.isEmpty {
            bodies = try await services.store.cards(in: nil).map(\.body)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bodies == ["来自扩展"])
    }
}
