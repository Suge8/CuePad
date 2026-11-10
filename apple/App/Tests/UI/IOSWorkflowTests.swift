#if os(iOS)
@testable import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct IOSWorkflowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func handOff(in project: UUID) async throws -> (task: Card, request: DeliveryRequest) {
        let task = try await store.createTask("修乱序\n先复现", in: project)
        let draft = ComposerDraft(attachments: [Outbox(content: Outgoing.text(of: task), card: task.id, project: task.projectID)])
        let plan = try await store.handOffPlan(task.id, host: nil)
        let workspace = Workspace(services: app.services)

        workspace.prepareNewSession(draft, card: task.id, opening: try await store.opening(of: task.id, true), plan: plan)

        let start = try #require(workspace.newSession)
        let places = ProjectFolders.launchPlaces(
            projects: try await store.projects(), bindings: try await store.directoryBindings(), host: nil, workMac: try await store.workMac())
        let place = try #require(start.place(among: places))
        let preparedDraft = try #require(start.draft)
        let sending = try #require(workspace.submitSession(
            start, in: place, draft: preparedDraft, choice: AgentModelChoice(agents: [], agent: .pi, model: nil, thinking: nil),
            opened: Workspace.entering(start)))
        await sending.value
        #expect(workspace.sessionLaunching(start.launchKey).launch != nil)
        return (task, try #require(try await store.deliveryRequests().first))
    }

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
    @Test(arguments: ["offline", "sent", "unconfirmed"])
    func 同一任务关闭重开_恢复原请求且不能冒充首次提交(state: String) async throws {
        defer { app.services.cancelBackgroundWork() }
        try await store.recordMacAgents(host: "mac-z", name: "Mac", [])
        let (task, first) = try await handOff(in: Project.defaultID)
        if state != "offline" {
            var row = try #require(try await store.syncRow(recordName: first.id.uuidString.lowercased()))
            if state == "unconfirmed" {
                row.fields["status"] = .text("unconfirmed")
                row.fields["handledBy"] = .text("mac-z")
                row.fields["modifiedAt"] = .int(row.modifiedAt + 1000)
            }
            #expect(try await store.applyRemote([.save(row, systemFields: Data(), serverAt: Date())]).isEmpty)
        }
        let workspace = Workspace(services: app.services)
        let draft = ComposerDraft(attachments: [Outbox(content: Outgoing.text(of: task), card: task.id, project: task.projectID)])
        let plan = try await store.handOffPlan(task.id, host: nil)
        workspace.handOff(task)
        workspace.handOffToNewSession(draft, card: task.id, plan: plan)
        workspace.newSession = nil
        workspace.handOff(task)
        workspace.handOffToNewSession(draft, card: task.id, plan: plan)
        let start = try #require(workspace.newSession)
        await #expect(throws: CueStoreError.deliveryAlreadyHanded) {
            try await app.services.launchSession(in: task.projectID, prompt: first.launch?.prompt, title: task.heading,
                                                on: "mac-z", card: task.id, agent: .pi)
        }
        #expect(try await store.deliveryRequests().map(\.id) == [first.id])
        let resumed = try #require(start.launched)
        #expect(resumed.request == first.id)
        let progress = try store.snapshot { try resumed.progress(from: $0) }.value
        switch state {
        case "offline":
            #expect(progress.phase(at: app.services.speech).submission == .safe)
        case "sent":
            #expect(progress.phase(at: app.services.speech).submission == .waiting)
        default:
            #expect(progress.phase(at: app.services.speech).submission == .confirm)
            _ = try await app.services.launchSession(in: task.projectID, prompt: first.launch?.prompt, title: task.heading,
                                                 on: "mac-z", card: task.id, agent: .pi, intent: .repeatingConfirmed)
            #expect(try await store.deliveryRequests().count == 2)
            #expect(try await store.deliveryRequest(first.id)?.status == .known(.unconfirmed))
        }
    }

}
#endif
