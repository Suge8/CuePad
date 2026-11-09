@testable import CueStore
import Foundation
import Testing
@testable import CuePad

/// 新会话的三个入口（Mac 的新会话表单、Mac 任务的"开始"、手机的新会话输入框）同一套规则（`SessionLaunching`）：
/// 首次开；明确没开成时直接重试，新请求替换失败的那条；结果未确认时先问，取消不动原请求与草稿，确认后另开；认领后各回各的去处；
/// 结果未确认时关掉表单或输入框接着等：晚到的认领照样收尾，重开后再开照样先问；同一任务已有没收尾的请求时 Store 拒绝冒充首次的交出。
@MainActor
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

    /// 打开一个入口（为一件新任务），返回任务、入口的那一份与提交动作（界面上点"开始"调的同一个；确认框里的"仍然再开"是 `launchAgain`）。
    private func open(_ entry: Entry, in workspace: Workspace) async throws -> (Card, SessionLaunching, () -> Task<Void, Never>?) {
        let task = try await store.createTask("修乱序\n先复现")
        let choice = AgentModelChoice(agents: [], agent: .pi, model: nil, thinking: nil)
        switch entry {
        #if os(macOS)
        case .form:
            workspace.showsNewSession = true
            let project = try #require(try await store.project(Project.defaultID))
            let place = ProjectFolders.launchPlaces(projects: [project], bindings: [], host: host, workMac: nil).first
            return (task, workspace.sessionLaunching(.form), {
                workspace.submitSession(in: place, draft: ComposerDraft(text: "修乱序"), choice: choice) { workspace.showLaunched($0.sessionID) }
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
                    start, in: start.place(among: places), draft: start.draft ?? ComposerDraft(), choice: choice, opened: workspace.entering(start))
            })
        #endif
        default:
            Issue.record("\(entry) 不在这一端")
            throw CancellationError()
        }
    }

    /// 那台 Mac 把在等的请求都写成 `outcome`。
    private func mac(answers outcome: DeliveryOutcome, _ launching: SessionLaunching, until phase: (LaunchProgress.Phase) -> Bool) async throws {
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { Issue.record("\($0)") }) { _, _ in outcome }
        try await executor.start()
        try await eventually("入口读到 Mac 写回的结果") { phase(launching.phase(at: app.services.speech)) }
        await executor.stop()
    }

    /// 关上表单或输入框；返回重新打开它的动作（同一份开场）。
    private func close(_ entry: Entry, in workspace: Workspace) -> () -> Void {
        #if os(macOS)
        workspace.showsNewSession = false
        return { workspace.showsNewSession = true }
        #else
        let start = workspace.newSession
        workspace.newSession = nil
        return { workspace.newSession = start }
        #endif
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
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: "s1", state: .thinking, title: "修乱序", launchToken: token)
        try await eventually("认领到新会话") { launching.launch == nil }
        let route: SessionRoute? = if case .session(let route) = workspace.mainRoute { route } else { nil }
        switch entry {
        case .form:
            #if os(macOS)
            #expect(!workspace.showsNewSession)
            #endif
            #expect(route?.sessionID == "s1", "表单收起，进入新会话")
        case .task: #expect(route == nil, "任务的开始不换页")
        case .input:
            #if os(iOS)
            #expect(workspace.newSession == nil)
            #endif
            #expect(route?.id == PiSessionState.recordID(sessionID: "s1"), "输入框收起，进入新会话")
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
        if entry == .form { #expect(workspace.showsNewSession) }
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
        let other = try await store.requestLaunch(PiLaunch(project: Project.defaultID, prompt: nil, token: "elsewhere"), title: "修乱序", on: host, card: task.id)
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
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: "s1", state: .thinking, title: "修乱序", launchToken: token)
        try await eventually("晚到的认领收尾这一次") { launching.launch == nil }
        let route: SessionRoute? = if case .session(let route) = workspace.mainRoute { route } else { nil }
        #if os(macOS)
        #expect(route?.sessionID == "s1", "Mac 的表单关了也进入新会话")
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
}
