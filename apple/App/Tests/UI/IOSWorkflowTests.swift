#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// iOS 发给 Agent 默认开新会话：新会话输入框默认的项目、哪台 Mac、会话名都是交到哪的决定（`CueStore.handOffPlan`）。
struct IOSWorkflowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// 一条带着正文的叶子任务，带着它打开发给 Agent 输入框（`Workspace.handOff` 带进来的那样），按默认的去处开新会话，返回写下的请求。
    private func handOff(in project: UUID) async throws -> (task: Card, request: DeliveryRequest) {
        let task = try await store.createTask("修乱序\n先复现", in: project)
        let draft = ComposerDraft(attachments: [Outbox(content: Outgoing.text(of: task), card: task.id, project: task.projectID)])
        let plan = try await store.handOffPlan(task.id, host: nil)
        let workspace = Workspace(services: app.services)

        HandOffInput.startDefault(draft, card: task.id, plan: plan, opening: try await store.opening(of: task.id, true), workspace: workspace)

        let start = try #require(workspace.newSession)
        let places = ProjectFolders.launchPlaces(
            projects: try await store.projects(), bindings: try await store.directoryBindings(), host: nil, workMac: try await store.workMac())
        let place = try #require(start.place(among: places)), host = try #require(place.host)
        _ = try await start.launch(in: place.project, on: host, draft: try #require(start.draft), agent: .pi, model: nil, thinking: nil, services: app.services)
        return (task, try #require(try await store.deliveryRequests().first))
    }

    /// 一台 Mac 都没打开过 CuePad 时开不了，说清楚要先在 Mac 上打开它。项目哪台 Mac 都没绑文件夹：交给干活的那台 Mac
    /// （Cue 在用的，没有就是按 Mac 自报的名字排第一台），由它建好工作区开会话；项目绑在两台 Mac 上也按名字排第一台。
    @Test func 发给Agent默认开新会话_项目Mac会话名都按交到哪的决定() async throws {
        let orphan = try await store.createTask("没处去", in: Project.defaultID)
        await #expect(throws: CueStoreError.noMac) { try await store.handOffPlan(orphan.id, host: nil) }
        try await store.recordMacAgents(host: "mac-z", name: "Alpha", [])
        try await store.recordMacAgents(host: "mac-a", name: "Zulu", [])

        let unbound = try await handOff(in: Project.defaultID).request
        #expect(unbound.launch?.project == Project.defaultID && unbound.hostID == "mac-z")

        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/table", for: project.id)
        try await store.publishDirectoryBindings(host: "mac-z")
        try await store.publishDirectoryBindings(host: "mac-a")
        let (task, request) = try await handOff(in: project.id)
        #expect(request.launch?.project == project.id && request.hostID == "mac-z")
        #expect(request.launch?.name == "修乱序" && request.target.name == "修乱序" && request.cardID == task.id)
        #expect(request.launch?.prompt == "修乱序\n先复现")
    }
}
#endif
