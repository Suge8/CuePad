#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// iOS 界面的跨边界合同：发到 Mac 的请求形状（Mac 执行器按它执行）、发给 Agent 默认开新会话、随手记带图入库。
struct IOSWorkflowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func session(_ id: String, _ state: PiWorkState, host: String) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: id, state: state, title: id)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == id })
    }

    // MARK: 发到 Mac

    @Test func 作答_请求发给会话所在的Mac_带这次弹窗的标识_答案与所答的问题() async throws {
        let question = PiQuestion(promptID: "p-7", kind: .select, text: "覆盖吗？", options: ["覆盖", "取消"])
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: "atlas", state: .waitingForUser, title: "atlas", question: question)
        let session = try #require(try await store.allPiSessionStates().first)

        let request = try await app.services.answer(.option("覆盖"), to: session)

        #expect(request.hostID == "mac-b" && request.mode == .known(.answer))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
        // 问题原文随答案带去：作答成功后连同答案写进对话
        #expect(request.answer == PiAnswer(promptID: "p-7", value: .option("覆盖"), question: "覆盖吗？"))
    }

    @Test func 发到Mac_请求指定会话所在的Mac_目标是该会话() async throws {
        let target = try await session("atlas", .settled, host: "mac-b")
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "正文"), to: target, mode: .send)
        #expect(request.hostID == "mac-b")
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
        #expect(request.mode == .known(.send))
        #expect(request.status == .known(.pending))
    }

    // MARK: 发给 Agent

    /// 一条带着正文的叶子任务，和带着它的发给 Agent 输入框草稿（`Navigation.handToAgent` 带进来的那样）。
    private func leaf(in project: UUID) async throws -> (task: Card, draft: ComposerDraft) {
        let task = try await store.createTask("修乱序\n先复现", in: project)
        return (task, ComposerDraft(attachments: [Outbox(content: Outgoing.text(of: task), card: task.id, project: task.projectID)]))
    }

    /// 项目哪台 Mac 都没绑文件夹：新会话交给干活的那台 Mac（Cue 在用的，没有就是按名字排第一台），由它建好工作区开会话；
    /// 一台 Mac 都没打开过 CuePad 时开不了，说清楚要先在 Mac 上打开它。
    @Test func 发给Agent默认开新会话_没绑文件夹的项目交给干活的那台Mac() async throws {
        let (task, draft) = try await leaf(in: Project.defaultID)
        await #expect(throws: CueStoreError.noMac) { try await store.handOffPlan(task.id, host: nil) }

        try await store.recordMacAgents(host: "mac-z", name: "Alpha", [])
        try await store.recordMacAgents(host: "mac-a", name: "Zulu", [])
        let plan = try await store.handOffPlan(task.id, host: nil)
        #expect(plan.destination == .launch(project: Project.defaultID, host: "mac-z"))
        let workspace = Workspace(services: app.services), navigation = Navigation(settings: app.services.settings)

        HandOffInput.startDefault(
            draft, card: task.id, plan: plan, opening: try await store.opening(of: task.id, true), workspace: workspace, navigation: navigation)

        let start = try #require(navigation.newSession)
        let places = ProjectFolders.launchPlaces(
            projects: try await store.projects(), bindings: try await store.directoryBindings(), host: nil, workMac: try await store.workMac())
        let place = try #require(start.place(among: places)), host = try #require(place.host)
        _ = try await start.launch(in: place.project, on: host, draft: try #require(start.draft), agent: .pi, model: nil, thinking: nil, services: app.services)
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.launch?.project == Project.defaultID && request.hostID == "mac-z")
    }

    /// 默认目标是新会话时点发送：新会话输入框默认的项目、哪台 Mac、会话名都是交到哪的决定（`CueStore.handOffPlan`）。
    /// 项目绑在两台 Mac 上。
    @Test func 发给Agent默认开新会话_项目Mac会话名都按交到哪的决定() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/table", for: project.id)
        try await store.publishDirectoryBindings(host: "mac-z", workspaces: Workspaces(root: URL(filePath: "/Users/me/CuePad")))
        try await store.publishDirectoryBindings(host: "mac-a", workspaces: Workspaces(root: URL(filePath: "/Users/me/CuePad")))
        try await store.recordMacAgents(host: "mac-z", name: "Alpha", [])
        try await store.recordMacAgents(host: "mac-a", name: "Zulu", [])
        let (task, draft) = try await leaf(in: project.id)
        let plan = try await store.handOffPlan(task.id, host: nil)
        #expect(plan.destination == .launch(project: project.id, host: "mac-z") && plan.name == "修乱序")  // 按 Mac 自报的名字排第一台
        let workspace = Workspace(services: app.services), navigation = Navigation(settings: app.services.settings)

        HandOffInput.startDefault(
            draft, card: task.id, plan: plan, opening: try await store.opening(of: task.id, true), workspace: workspace, navigation: navigation)

        let start = try #require(navigation.newSession)
        let places = ProjectFolders.launchPlaces(
            projects: try await store.projects(), bindings: try await store.directoryBindings(), host: nil, workMac: try await store.workMac())
        let place = try #require(start.place(among: places)), host = try #require(place.host)
        _ = try await start.launch(in: place.project, on: host, draft: try #require(start.draft), agent: .pi, model: nil, thinking: nil, services: app.services)
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.launch?.project == project.id && request.hostID == "mac-z")
        #expect(request.launch?.name == "修乱序" && request.target.name == "修乱序" && request.cardID == task.id)
        #expect(request.launch?.prompt == "修乱序\n先复现")
    }

    // MARK: 随手记

    @Test func 随手记带图_存为一张卡_文字在前图片按顺序在后_落在指定项目并提示落点() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services)
        let first = pngData(shade: 0.1), second = pngData(shade: 0.9)
        let hashes = try [first, second].map { try app.services.store.files.store($0) }

        try await CaptureDraft(text: "  想法  ", images: [first, second]).save(in: project.id, workspace: workspace)

        let card = try #require(try await store.cards(in: project.id).first)
        #expect(card.body == "想法\n\n![](cuepad://img/\(hashes[0]))\n![](cuepad://img/\(hashes[1]))")
        #expect(workspace.notice?.text == "已记到 圆桌")
        #expect(workspace.notice?.link == .project(project.id))
    }
}
#endif
