@testable import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct NewSessionFlowTests {
    nonisolated enum Entry: Sendable, CustomTestStringConvertible {
        case form, task, input
        var testDescription: String { "\(self)" }
        #if os(macOS)
        static let all: [Entry] = [.form, .task]
        static let forCards: [Entry] = [.task]
        static let closable: [Entry] = [.form]
        #else
        static let all: [Entry] = [.input]
        static let forCards: [Entry] = [.input]
        static let closable: [Entry] = [.input]
        #endif
    }

    let app = TestApp()
    var store: CueStore { app.services.store }
    #if os(macOS)
    let host = TestApp.hostID
    #else
    let host = "mac-a"
    #endif

    private func open(_ entry: Entry, in workspace: Workspace) async throws -> (Card, SessionLaunching, () -> Task<Void, Never>?) {
        let task = try await store.createTask("修乱序\n先复现")
        let choice = AgentModelChoice(agents: [], agent: .pi, model: nil, thinking: nil)
        switch entry {
        #if os(macOS)
        case .form:
            workspace.openNewSession()
            let start = try #require(workspace.newSession)
            let project = try #require(try await store.project(Project.defaultID))
            let place = ProjectFolders.launchPlaces(projects: [project], bindings: [], host: host, workMac: nil).first
            return (task, workspace.sessionLaunching(.form), {
                workspace.submitSession(start, in: place, draft: ComposerDraft(text: "修乱序"), choice: choice, opened: Workspace.entering(start))
            })
        case .task:
            try await app.offersPi()
            return (task, workspace.sessionLaunching(.card(task.id)), { workspace.handOff(task) })
        #else
        case .input:
            try await store.recordMacAgents(host: host, name: "Mac", [])
            workspace.handOff(task)
            workspace.handOffToNewSession(
                ComposerDraft(attachments: [try #require(workspace.outbox)]), card: task.id, plan: try await store.handOffPlan(task.id, host: nil))
            let start = try #require(workspace.newSession)
            let places = ProjectFolders.launchPlaces(
                projects: try await store.projects(), bindings: try await store.directoryBindings(), host: nil, workMac: try await store.workMac())
            return (task, workspace.sessionLaunching(start.launchKey), {
                workspace.submitSession(
                    start, in: start.place(among: places), draft: start.draft ?? ComposerDraft(), choice: choice, opened: Workspace.entering(start))
            })
        #endif
        default:
            Issue.record("\(entry) 不在这一端")
            throw CancellationError()
        }
    }

    private func mac(answers outcome: DeliveryOutcome, _ launching: SessionLaunching, until phase: (LaunchProgress.Phase) -> Bool) async throws {
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { Issue.record("\($0)") }) { _, _ in outcome }
        try await executor.start()
        try await eventually("入口读到 Mac 写回的结果") { phase(launching.phase(at: app.services.speech)) }
        await executor.stop()
    }

    private func close(_ entry: Entry, in workspace: Workspace) -> () -> Void {
        let start = workspace.newSession
        workspace.newSession = nil
        return { workspace.newSession = start }
    }

    private func unconfirmedThenClosed(_ entry: Entry, in workspace: Workspace) async throws -> (SessionLaunching, SessionLaunch, () -> Void, () -> Task<Void, Never>?) {
        let (_, launching, submit) = try await open(entry, in: workspace)
        await submit()?.value
        let first = try #require(launching.launch)
        try await mac(answers: .unconfirmed(.verbatim("不知道开没开")), launching) { if case .unconfirmed = $0 { true } else { false } }
        return (launching, first, close(entry, in: workspace), submit)
    }

    private var requests: Set<UUID> { get async throws { Set(try await store.deliveryRequests().map(\.id)) } }

    @Test(arguments: Entry.all)
    func 首次开_没开成直接重试替换旧请求_认领后各回各处(entry: Entry) async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let (_, launching, submit) = try await open(entry, in: workspace)
        await submit()?.value
        let first = try #require(launching.launch)
        #expect(try await requests == [first.request])
        #expect(try await store.deliveryRequest(first.request)?.launch?.prompt?.hasPrefix("修乱序") == true)

        try await mac(answers: .failed(.verbatim("文件夹不在了")), launching) { $0 == .failed(.reported("文件夹不在了")) }
        #expect(launching.outcome(at: app.services.speech)?.text == "文件夹不在了")
        await submit()?.value
        #expect(!launching.confirmingAgain, "明确没开成不问")
        let second = try #require(launching.launch)
        #expect(try await requests == [second.request], "重试替换失败的那条")

        let token = try #require(try await store.deliveryRequest(second.request)?.launch?.token)
        try await StateRecorder(store: store, hostID: host).update(sessionID: "s1", state: .thinking, title: "修乱序", launchToken: token)
        try await eventually("认领到新会话") { launching.launch == nil }
        let route: SessionRoute? = if case .session(let route) = workspace.mainRoute { route } else { nil }
        switch entry {
        case .form:
            #expect(workspace.newSession == nil)
            #expect(route?.sessionID == "s1", "输入框收起，进入新会话")
        case .task: #expect(route == nil, "任务的开始不换页")
        case .input:
            #expect(workspace.newSession == nil)
            #expect(route?.id == SessionState.recordID(sessionID: "s1"), "输入框收起，进入新会话")
        }
    }

    @Test(arguments: Entry.all)
    func 未确认先问_取消不动原请求与草稿_确认后另开(entry: Entry) async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let (_, launching, submit) = try await open(entry, in: workspace)
        await submit()?.value
        let first = try #require(launching.launch)
        try await mac(answers: .unconfirmed(.verbatim("不知道开没开")), launching) { if case .unconfirmed = $0 { true } else { false } }

        #expect(submit() == nil)
        #expect(launching.confirmingAgain, "可能已开过，先问")
        #if os(iOS)
        let draft = workspace.newSession?.draft
        #endif
        launching.confirmingAgain = false
        #expect(try await requests == [first.request])
        #expect(launching.launch == first)
        #if os(macOS)
        if entry == .form { #expect(workspace.newSession != nil) }
        #else
        #expect(workspace.newSession?.draft?.stored == draft?.stored, "输入框和草稿都还在")
        #endif

        await launching.launchAgain()?.value
        let second = try #require(launching.launch)
        #expect(second != first)
        #expect(try await requests == [first.request, second.request])
        #expect(try await store.deliveryRequest(first.request)?.status == .known(.unconfirmed), "原请求保留")
    }

    @Test(arguments: Entry.forCards)
    func 任务已有没收尾的请求_Store拒绝冒充首次交出(entry: Entry) async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let (task, launching, submit) = try await open(entry, in: workspace)
        let other = try await store.requestLaunch(LaunchRequest(project: Project.defaultID, prompt: nil, token: "elsewhere"), title: "修乱序", on: host, card: task.id)
        await submit()?.value
        #expect(launching.launch == nil)
        #expect(launching.error == CueStoreError.deliveryAlreadyHanded.localizedDescription)
        #expect(workspace.notice?.isError == true)
        #expect(try await requests == [other.id])
    }

    @Test(arguments: Entry.closable)
    func 未确认后关上_晚到的认领照样收尾(entry: Entry) async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let (launching, first, _, _) = try await unconfirmedThenClosed(entry, in: workspace)
        #expect(launching.launch == first, "可能已开过：关上也接着等")

        let token = try #require(try await store.deliveryRequest(first.request)?.launch?.token)
        try await StateRecorder(store: store, hostID: host).update(sessionID: "s1", state: .thinking, title: "修乱序", launchToken: token)
        try await eventually("晚到的认领收尾这一次") { launching.launch == nil }
        let route: SessionRoute? = if case .session(let route) = workspace.mainRoute { route } else { nil }
        #if os(macOS)
        #expect(route?.sessionID == "s1", "Mac 的输入框关了也进入新会话")
        #else
        #expect(route == nil && workspace.newSession == nil, "手机的输入框关了就留在原处")
        #endif
    }

    @Test(arguments: Entry.closable)
    func 未确认后关上再开_再开照样先问(entry: Entry) async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let (launching, first, reopen, submit) = try await unconfirmedThenClosed(entry, in: workspace)
        reopen()
        #expect(launching.outcome(at: app.services.speech)?.text == "不知道开没开", "重开写着上一次的原因")
        #expect(submit() == nil)
        #expect(launching.confirmingAgain, "关一次不能绕过确认")
        await launching.launchAgain()?.value
        #expect(try await requests == [first.request, try #require(launching.launch).request])
    }

    #if os(macOS)
    @Test func 开始用这个项目上次选的那家_没选过的项目用最近一次选的() async throws {
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services), settings = app.services.settings
        try await store.recordMacAgents(host: host, name: "测试 Mac", [.pi, .codex].map { MacAgent(kind: $0, model: nil, models: []) })
        let table = try await store.createProject(name: "圆桌", color: "#000000")
        let flow = try await store.createProject(name: "Flow", color: "#000000")
        func started(in project: UUID) async throws -> AgentKind? {
            let task = try await store.createTask("修乱序", in: project)
            await workspace.handOff(task)?.value
            return try await store.deliveryRequests().first { $0.cardID == task.id }?.launch?.agent
        }

        settings.setLaunchPreference(for: table.id) { $0.agent = .codex }
        #expect(try await started(in: table.id) == .codex)
        #expect(try await started(in: flow.id) == .codex, "没选过的项目用最近一次选的")
        settings.setLaunchPreference(for: flow.id) { $0.agent = .pi }
        #expect(try await started(in: flow.id) == .pi)
        #expect(try await started(in: table.id) == .codex, "各项目记各自的")
    }
    #endif
}
