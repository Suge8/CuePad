#if os(iOS)
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

/// 输入组件的两条跨边界合同：草稿（文字、图片、带上的卡片）写成什么样的投送请求正文；Pi 的一条回答存为卡片落在哪、正文是什么。
@MainActor
struct ComposerTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func session(project: UUID? = nil) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas", projectID: project)
        return try #require(try await store.allPiSessionStates().first)
    }

    @Test func 回复带图片和卡片_正文依次是卡片_文字_图片_原图入库并关联卡片() async throws {
        let target = try await session()
        let photo = pngData(shade: 0.3)
        let hash = try store.files.store(pngData(shade: 0.8))
        let card = try await store.createCard(in: nil, body: "接口约定\n\n![](cuepad://img/\(hash))")
        let draft = ComposerDraft(
            text: "  照这个改  ", images: [PickedImage(data: photo)],
            attachment: Navigation.Outbox(content: card.body, card: card.id, project: nil))

        let request = try await app.services.requestMacDelivery(draft, to: target, mode: .send)

        let photoHash = try #require(CueFormat.imageHashes(in: request.content).last)
        #expect(request.content == "\(card.body)\n\n照这个改\n\n![](cuepad://img/\(photoHash))")
        #expect(app.services.images.fileURL(for: photoHash) != nil)
        #expect(request.cardID == card.id)
        #expect(request.hostID == "mac-a" && request.mode == .known(.send))
    }

    @Test func 草稿只有一张图片也能发_什么都没有的不能发() async throws {
        let target = try await session()

        let request = try await app.services.requestMacDelivery(
            ComposerDraft(images: [PickedImage(data: pngData())]), to: target, mode: .send)
        #expect(CueFormat.imageHashes(in: request.content).count == 1 && !request.content.contains("\n"))

        await #expect(throws: CueStoreError.blankDeliveryContent) {
            try await app.services.requestMacDelivery(ComposerDraft(text: "  "), to: target, mode: .send)
        }
    }

    @Test func 回答存为卡片_进会话所属项目_没有项目进未归档_提示落点并可点过去() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services, holder: SceneContext())

        try await workspace.saveReply("## 结论\n\n先迁移再切流量", of: try await session(project: project.id))
        #expect(try await store.cards(in: project.id).map(\.body) == ["## 结论\n\n先迁移再切流量"])
        #expect(workspace.notice?.text == "已记到 圆桌" && workspace.notice?.link == .project(project.id))

        try await workspace.saveReply("没归属的", of: try await {
            try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "loose", state: .settled, title: "loose")
            return try #require(try await store.allPiSessionStates().first { $0.sessionID == "loose" })
        }())
        #expect(try await store.cards(in: nil).map(\.body) == ["没归属的"])
        #expect(workspace.notice?.text == "已记到 未归档" && workspace.notice?.link == .project(nil))
    }
}
#endif
