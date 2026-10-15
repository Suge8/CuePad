#if os(iOS)
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

/// 输入组件的两条跨边界合同：草稿（文字、图片、带上的卡片）写成什么样的投送请求正文；Pi 的一条回答存为卡片落在哪、正文是什么。
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
            attachments: [Outbox(content: card.body, card: card.id, project: nil)])

        let request = try await Workspace(services: app.services).said(draft, to: target, mode: .send)

        let photoHash = try #require(CueFormat.imageHashes(in: request.content).last)
        #expect(request.content == "\(card.body)\n\n照这个改\n\n![](cuepad://img/\(photoHash))")
        #expect(app.services.store.files.fileURL(for: photoHash) != nil)
        #expect(request.cardID == card.id)
        #expect(request.hostID == "mac-a" && request.mode == .known(.send))
    }

    /// 发给 Agent 时用"＋ 选灵感"带上本项目的资料：卡片作为这次消息的附件跟着发出（任务的正文在前、资料在后），
    /// 卡片本身不动——仍在原项目的资料组里；请求关联的仍是那件任务。选卡片的面板里本项目资料排在最前。
    @Test func 交给Agent时带上资料作附件_正文含它_资料原地不动_面板里资料在最前() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let target = try await session(project: project.id)
        let task = try await store.createTask("修乱序\n先复现", in: project.id)
        let reference = try await store.createCard(in: project.id, body: "接口约定\n队列按首次加入时间排")
        try await store.updateCard(reference.id) { $0.isPinned = true }
        _ = try await store.createCard(in: project.id, body: "随手一条")

        let page = try await CardPicker.Page.read(text: "", project: project.id, limit: 30, from: store)
        #expect(page.resources.map(\.id) == [reference.id])
        #expect(!page.pinned.contains { $0.id == reference.id })

        var draft = ComposerDraft(attachments: [Outbox(content: Outgoing.text(of: task), card: task.id, project: project.id)])
        draft.attach(try #require(try await store.card(reference.id)))
        draft.attach(try #require(try await store.card(reference.id)))  // 同一张不重复带
        let request = try await Workspace(services: app.services).said(draft, to: target, mode: .send)

        #expect(request.content == "修乱序\n先复现\n\n接口约定\n队列按首次加入时间排")
        #expect(request.cardID == task.id)
        let after = try #require(try await store.card(reference.id))
        #expect(after.isPinned && after.projectID == project.id && after.parentID == nil)
        #expect(try await store.cards(in: project.id).filter(\.isPinned).map(\.id) == [reference.id])
    }

    /// 发给 Agent 的输入框是为某件任务打开的：请求始终关联这件任务（打开时定下，不随附件增删），
    /// 即使附件里只剩资料，状态点也在任务上、资料行不出现。
    @Test func 交给Agent时附件里没有那件任务_请求仍关联它_状态点在任务不在资料() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let target = try await session(project: project.id)
        let task = try await store.createTask("修乱序\n先复现", in: project.id)
        let reference = try await store.createCard(in: project.id, body: "接口约定")
        try await store.updateCard(reference.id) { $0.isPinned = true }

        var draft = ComposerDraft()
        draft.attach(try #require(try await store.card(reference.id)))
        let request = try await Workspace(services: app.services).said(draft, to: target, mode: .send, card: task.id)
        #expect(request.cardID == task.id)
        var handed = try await store.handedSessions()
        #expect(handed[task.id] == .session("atlas") && handed[reference.id] == nil)

        try await store.recordSend(request.content, to: request.target, card: request.cardID)  // Mac 执行
        handed = try await store.handedSessions()
        #expect(handed[task.id] == .session("atlas") && handed[reference.id] == nil)
        #expect(try await store.card(reference.id)?.piSessionID == nil)
    }

    @Test func 草稿只有一张图片也能发() async throws {
        let target = try await session()

        let request = try await Workspace(services: app.services).said(ComposerDraft(images: [PickedImage(data: pngData())]), to: target, mode: .send)
        #expect(CueFormat.imageHashes(in: request.content).count == 1 && !request.content.contains("\n"))
    }

    @Test func 回答存为卡片_进会话所属项目_没有项目进未分类_提示落点并可点过去() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services)

        try await workspace.saveReply("## 结论\n\n先迁移再切流量", of: try await session(project: project.id))
        #expect(try await store.cards(in: project.id).map(\.body) == ["## 结论\n\n先迁移再切流量"])
        #expect(workspace.notice?.text == "已记到 圆桌" && workspace.notice?.link == .project(project.id))

        try await workspace.saveReply("没归属的", of: try await {
            try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "loose", state: .settled, title: "loose")
            return try #require(try await store.allPiSessionStates().first { $0.sessionID == "loose" })
        }())
        #expect(try await store.cards(in: nil).map(\.body) == ["没归属的"])
        #expect(workspace.notice?.text == "已记到 未分类" && workspace.notice?.link == .unfiled)
    }
}
#endif
