import CueEditor
import CueStore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CuePad

@Suite(.releasesLibraries)
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

    @Test func 图片网址文字各取所需_图片当文件收() async throws {
        let png = pngData()
        let content = try await ShareItemLoader.load(from: [
            provider(text: "  标题  "), provider(url: "https://example.com/a"), provider(image: png), provider(text: "第二段"),
        ])

        #expect(content.text == "标题\n\n第二段")
        #expect(content.urls == [URL(string: "https://example.com/a")!])
        #expect(content.files.count == 1)
        #expect(try content.files.map { try Data(contentsOf: $0.url) } == [png])
    }

    @Test func 选项目保存后主App入库成所选项目里的卡片() async throws {
        let app = TestApp()
        let location = app.services.location
        let project = try await app.services.store.createProject(name: "A", color: "#111111")
        try Snapshots.write(
            ProjectsSnapshot(projects: [.init(id: project.id, name: "A", color: "#111111", icon: nil)]),
            to: location.snapshotsDirectory)
        let target = try #require(Snapshots.read(ProjectsSnapshot.self, from: location.snapshotsDirectory)?.projects.first)
        let model = ShareModel(providers: [provider(text: "记一下")], location: location)
        #expect(model.projects?.map(\.name) == ["A"])
        await model.load()
        #expect(model.state == .ready)
        model.selectedProject = target.id

        let saved = await model.save()

        #expect(saved)
        await app.services.drainCaptures()
        #expect(try await app.services.store.cards(in: target.id).map(\.body) == ["记一下"])
    }

    @Test func 没有可保存的内容时进入失败状态_不写任何东西() async throws {
        let app = TestApp()
        let model = ShareModel(providers: [provider(text: "   ")], location: app.services.location)

        await model.load()
        let saved = await model.save()

        #expect(!saved)
        guard case .failed = model.state else { Issue.record("状态应为失败：\(model.state)"); return }
        #expect(CaptureQueue.pending(in: app.services.location.captureDirectory).isEmpty)
    }
    @Test func 分享与粘贴临时副本_保留原名并只补缺少的扩展名() async throws {
        let app = TestApp()
        let cases: [(String?, String, String)] = [
            ("中文报告", "system.pdf", "中文报告.pdf"),
            ("报告.PDF", "system.pdf", "报告.PDF"),
            (nil, "system.pdf", "system.pdf"),
            ("无扩展名", "system", "无扩展名"),
        ]
        for (suggested, filename, expected) in cases {
            let url = app.directory.appending(path: filename)
            try Data("文件正文".utf8).write(to: url)
            let provider = NSItemProvider()
            provider.suggestedName = suggested
            provider.registerFileRepresentation(forTypeIdentifier: (url.pathExtension.isEmpty ? UTType.data : .pdf).identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            let content = try await ShareItemLoader.load(from: [provider])
            #expect(content.files.map(\.name) == [expected])
            #if os(iOS)
            let pasted = try await IncomingFile.pasted(PastedItem(provider)).store(in: app.services.store.files)
            #expect(pasted.name == expected)
            #endif
        }
    }

}
