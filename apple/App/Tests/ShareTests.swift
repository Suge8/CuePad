import CueStore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CuePad

@MainActor
struct ShareTests {
    private func provider(text: String) -> NSItemProvider { NSItemProvider(object: text as NSString) }
    private func provider(url: String) -> NSItemProvider { NSItemProvider(object: URL(string: url)! as NSURL) }
    private func provider(image data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @Test func 图片网址文字各取所需() async throws {
        let png = pngData()
        let content = try await ShareItemLoader.load(from: [
            provider(text: "  标题  "), provider(url: "https://example.com/a"), provider(image: png), provider(text: "第二段"),
        ])

        #expect(content.text == "标题\n\n第二段")
        #expect(content.urls == [URL(string: "https://example.com/a")!])
        #expect(content.images == [.init(data: png, fileExtension: "png")])
    }

    @Test func 没有可保存的内容时报错() async {
        await #expect(throws: ShareError.self) { try await ShareItemLoader.load(from: [provider(text: "   ")]) }
        await #expect(throws: ShareError.self) { try await ShareItemLoader.load(from: []) }
    }

    @Test func 选项目保存后进待入库目录并可被主App读到() async throws {
        let app = TestApp()
        let location = app.services.location
        try Snapshots.write(
            ProjectsSnapshot(projects: [.init(id: UUID(), name: "A", color: "#111111", icon: nil)]),
            to: location.snapshotsDirectory)
        let target = try #require(Snapshots.readProjects(from: location.snapshotsDirectory)?.projects.first)
        let model = ShareModel(providers: [provider(text: "记一下")], location: location)
        #expect(model.projects.map(\.name) == ["A"])
        await model.load()
        #expect(model.state == .ready)
        model.selectedProject = target.id

        let saved = await model.save()

        #expect(saved)
        let entry = try #require(CaptureQueue.pending(in: location.captureDirectory).first)
        #expect(entry.capture.text == "记一下")
        #expect(entry.capture.project == target.id)
    }

    @Test func 内容读不出来时进入失败状态_不写任何东西() async throws {
        let app = TestApp()
        let model = ShareModel(providers: [], location: app.services.location)

        await model.load()
        let saved = await model.save()

        #expect(!saved)
        guard case .failed = model.state else { Issue.record("状态应为失败：\(model.state)"); return }
        #expect(CaptureQueue.pending(in: app.services.location.captureDirectory).isEmpty)
    }
}
