#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 上提示词"交给哪里"：编辑页底栏、右键菜单、⌘K 与选区菜单读同一个 `SendState.destination`：一个任务一个会话，
/// 同一任务的提示词接着发到同一个会话，新任务默认开新会话，挑过的去处只对那个任务生效。
/// 会话结束后去处不悄悄换掉，而是写明"已结束"（交出时在后台唤醒）；同一个 Pi 会话重新打开了就接回新开的那个。
struct SendTargetTests {
    let rig = TestApp()
    let workspace: Workspace
    let project: Project
    let other: Project
    private var store: CueStore { rig.services.store }
    /// 假扩展一释放连接就断开（会话就结束了），所以连着的都留在这里，直到测试结束。
    private let opened = Opened()
    private final class Opened { var extensions: [FakeExtension] = [] }

    init() async throws {
        project = try await rig.services.store.createProject(name: "Work", color: "blue")
        other = try await rig.services.store.createProject(name: "Other", color: "red")
        try await rig.services.store.setDirectory("/work", for: project.id)
        try await rig.services.store.setDirectory("/other", for: other.id)
        workspace = Workspace(services: rig.services)
        let changes = rig.pi.changes()  // 先订阅再连上会话：桥的变化写成同步记录
        try rig.pi.start()
        let services: AppServices = rig.services
        Task {
            do { try await services.consumePiChanges(changes) } catch { Issue.record(error) }
        }
        rig.services.startLiveSessions()
    }

    /// 一个连着桥的 Pi 会话（同一个会话重新打开时 `pid` 不同）。
    private func open(_ sessionID: String, in directory: String, pid: Int32 = 100) async throws -> FakeExtension {
        // 说过话的会话才有会话文件：结束后进历史（没有文件的结束时不进历史）
        let file = FileManager.default.temporaryDirectory.appending(path: "send-target-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let ext = FakeExtension(directory: rig.socketDirectory, sessionID: sessionID, pid: pid, options: .init(cwd: directory, sessionFile: file.path))
        try ext.start()
        opened.extensions.append(ext)
        try await eventually("rig.pi.session(id: ext.id) != nil") { rig.pi.session(id: ext.id) != nil }
        #expect(rig.pi.session(id: ext.id) != nil)
        try await workspace.sendState.refreshSessionProjects()
        return ext
    }

    private func end(_ ext: FakeExtension) async throws {
        ext.close(bye: "quit")
        try await eventually("rig.pi.session(id: ext.id) == nil") { rig.pi.session(id: ext.id) == nil }
        try await workspace.sendState.refreshSessionProjects()
    }

    /// 任务和它下面的一条提示词；`in project` 为 nil 是没归入项目的。
    private func prompt(in project: Project?) async throws -> (task: Card, prompt: Card) {
        let task = try await store.createTask("任务", in: project?.id)
        return (task, try await store.createCard(body: "提示词", under: task.id))
    }

    /// 同一任务再加一条提示词。
    private func sibling(of task: Card) async throws -> Card {
        try await store.createCard(body: "另一条提示词", under: task.id)
    }

    /// 等提示词的去处成为 `expected`：会话状态经桥、同步记录、观察流一路过来，没有更细的信号。每次按库里最新的提示词与任务算。
    private func expectDestination(
        _ id: UUID, _ expected: HandOffDestination?, in window: Workspace? = nil, _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let sendState = (window ?? workspace).sendState
        let prompt = try #require(try await store.card(id))
        let task = try await store.card(try #require(prompt.parentID))
        // 等不到时不在这里停：下面带着现场的断言说得更清楚
        try? await eventually("去处成为 \(String(describing: expected))") { sendState.destination(of: prompt, task: task) == expected }
        let destination = sendState.destination(of: prompt, task: task)
        #expect(destination == expected, comment ?? Comment(rawValue: "live=\(rig.pi.sessions.map(\.id)) projects=\(workspace.sendState.projects)"), sourceLocation: sourceLocation)
    }

    @Test func 同一任务的提示词接着发到同一个会话_新任务默认开新会话() async throws {
        _ = try await open("a", in: "/work/alpha")
        _ = try await open("b", in: "/work/beta")
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let (task, first) = try await prompt(in: project)
        let second = try await sibling(of: task)
        let (_, elsewhere) = try await prompt(in: project)
        try await expectDestination(first.id, .newSession, "本项目有在线会话，但没交给过：任务默认开新会话")

        workspace.sendState.pick(.session("a"), for: first)
        workspace.handOff(first)
        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "a" }

        let nextWindow = Workspace(services: rig.services)
        #expect(nextWindow.sendState.picks.isEmpty)
        try await expectDestination(second.id, .session("a"), in: nextWindow, "没人挑过：靠任务上次交给的会话")
        try await expectDestination(elsewhere.id, .newSession, "别的任务不跟着走")
    }

    @Test func 挑过的去处只对所在任务生效() async throws {
        _ = try await open("a", in: "/work/alpha")
        let (task, first) = try await prompt(in: project)
        let second = try await sibling(of: task)
        let (_, other) = try await prompt(in: project)

        workspace.sendState.pick(.session("a"), for: first)

        try await expectDestination(first.id, .session("a"))
        try await expectDestination(second.id, .session("a"), "同一任务的提示词一起")
        try await expectDestination(other.id, .newSession)
    }

    @Test func 挑过新会话_压过任务上次交给的会话() async throws {
        _ = try await open("a", in: "/work/alpha")
        let (_, first) = try await prompt(in: project)
        try await store.linkCard(first.id, toSession: "a")
        try await expectDestination(first.id, .session("a"))

        workspace.sendState.pick(.newSession, for: first)

        try await expectDestination(first.id, .newSession)
    }

    @Test func 没归入项目的提示词没有默认去处_挑过或交给过会话才有() async throws {
        _ = try await open("a", in: "/work/alpha")
        let (_, loose) = try await prompt(in: nil)
        try await expectDestination(loose.id, nil, "没有项目就没有可开新会话的文件夹，也不借用别的项目的会话")

        workspace.sendState.pick(.session("a"), for: loose)
        try await expectDestination(loose.id, .session("a"))

        let (_, linked) = try await prompt(in: nil)
        try await store.linkCard(linked.id, toSession: "a")
        try await expectDestination(linked.id, .session("a"))
    }

    @Test func 项目里没交给过的提示词_交出时在项目文件夹开新会话() async throws {
        let folder = rig.directory.appending(path: "work/new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await store.setDirectory(folder.path, for: project.id)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let (_, first) = try await prompt(in: project)

        workspace.handOff(first)

        try await eventually("rig.host.calls 里有在项目文件夹打开") {
            rig.host.calls.contains { call in
                if case .open(let directory, _) = call { directory == folder.path } else { false }
            }
        }
    }

    @Test func 会话结束后去处写明已结束_交出时在后台唤醒它() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        let (_, first) = try await prompt(in: project)
        workspace.sendState.pick(.session("a"), for: first)
        try await expectDestination(first.id, .session("a"))
        let folder = rig.directory.appending(path: "work/alpha", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "/sessions/--work-alpha--/a.jsonl"
        try await store.upsertPiSession(PiSession(id: "a", path: file, cwd: folder.path, title: "alpha", lastActivityAt: .now), host: TestApp.hostID)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }

        try await end(alpha)

        try await eventually("workspace.sendState.isEnded(a)") { workspace.sendState.isEnded(AgentTarget(session: "a")) }
        try await expectDestination(first.id, .session("a"), "结束了也不换成别的")
        #expect(workspace.sendState.action(for: AgentTarget(session: "a")) == "唤醒 Agent 会话「alpha」并发送")
        #expect(workspace.sendState.endedTargets.map(\.sessionID) == ["a"], "菜单里列的就是这一批")

        workspace.handOff(first)

        try await eventually("唤醒后话送到") { rig.host.extensions["a"]?.messages.isEmpty == false }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.target == SendTarget(kind: .piSession, name: "alpha", ref: "a") && request.mode == .known(.send))
        #expect(rig.host.calls == [.resume(sessionFile: file, directory: folder.path)])
        #expect(rig.host.extensions["a"]?.messages == [PiMessage(text: "提示词", deliveryID: request.id.uuidString)])
        try await eventually("workspace.sendState.endedTargets.isEmpty") { workspace.sendState.endedTargets.isEmpty }
        #expect(workspace.sendState.isEnded(AgentTarget(session: "a")) == false, "唤醒后它又在线了")
    }

    @Test func 唤醒不了_会话文件不在这台Mac上_交出失败不假成功() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        try await end(alpha)
        try await eventually("workspace.sendState.isEnded(a)") { workspace.sendState.isEnded(AgentTarget(session: "a")) }

        #expect(await workspace.send("接着做", to: AgentTarget(session: "a")) == false)

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.status == .known(.failed))
        #expect(rig.host.calls.isEmpty)
    }

    /// 别的 Mac 上在线的会话（同步记录里 hostID 不是本机）：与本机的会话一样是提示词的去处。
    private func remoteSession(_ id: String, title: String, in project: Project, state: PiWorkState = .settled) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: id, state: state, title: title, folder: title, projectID: project.id)
    }

    @Test func 交给别的Mac上的会话_写一条指定那台Mac的投送请求_本机不执行() async throws {
        try await remoteSession("r", title: "atlas", in: project)
        let (_, first) = try await prompt(in: project)
        try await store.linkCard(first.id, toSession: "r")
        try await expectDestination(first.id, .session("r"))

        #expect(await workspace.send("接着做", to: AgentTarget(session: "r")))

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.send))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "r"))
        #expect(rig.host.calls.isEmpty && rig.pi.sessions.isEmpty, "本机没有执行它")
    }

    @Test func 别的Mac上的会话正忙_先问马上说还是等它做完再说() async throws {
        try await remoteSession("r", title: "atlas", in: project, state: .thinking)
        let (_, first) = try await prompt(in: project)
        workspace.sendState.pick(.session("r"), for: first)
        try await expectDestination(first.id, .session("r"))

        workspace.handOff(first)
        try await eventually("workspace.sendState.busy?.session == r") { workspace.sendState.busy?.session == "r" }
        #expect(try await store.deliveryRequests().isEmpty)

        workspace.resolveBusySend(.steer)
        _ = try await eventually(store, { try $0.deliveryRequests().count }) { $0 > 0 }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.steer))
    }

    /// Mac 的去处菜单与手机的交给 Agent 输入框列的是同一批在线会话。
    @Test func 去处菜单与手机的目标列表是同一批() async throws {
        _ = try await open("a", in: "/work/alpha")
        _ = try await open("b", in: "/work/beta")
        try await remoteSession("r", title: "atlas", in: project)
        try await remoteSession("gone", title: "old", in: project, state: .ended)
        try await eventually("workspace.sendState.onlineTargets(for: project.id).count == 3") { workspace.sendState.onlineTargets(for: project.id).count == 3 }

        let mac = workspace.sendState.onlineTargets(for: project.id).map(\.state.sessionID)
        let phone = HandOffTargets.sessions(rig.services.liveSessions.live, project: project.id).map(\.state.sessionID)

        #expect(mac == phone && Set(mac) == ["a", "b", "r"])
        #expect(workspace.sendState.endedTargets.isEmpty, "别的 Mac 上结束的不是本机刚结束的")
    }

    /// 同步记录里还写着"在线"的本机会话，桥上却已经没有了（还没来得及标成结束）：不是能交给的会话，菜单不列、也不当上次的去处；
    /// 与发送走的路（已结束）是同一个判定。
    @Test func 本机记录里在线但桥上已没有的会话不列() async throws {
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "stale", state: .settled, title: "stale", folder: "stale", projectID: project.id)
        try await eventually("liveSessions.live == [stale]") { rig.services.liveSessions.live.map(\.state.sessionID) == ["stale"] }
        let (_, first) = try await prompt(in: project)
        try await store.linkCard(first.id, toSession: "stale")

        #expect(workspace.sendState.onlineTargets(for: project.id).isEmpty)
        try await expectDestination(first.id, .newSession)
        if case .ended = workspace.sendState.route(of: "stale") {} else { Issue.record("发送时它是已结束的会话") }
    }

    @Test func 挑过的会话结束了也不换成别的() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        _ = try await open("b", in: "/work/beta")
        let (_, first) = try await prompt(in: project)
        workspace.sendState.pick(.session("a"), for: first)
        try await expectDestination(first.id, .session("a"))

        try await end(alpha)

        try await eventually("workspace.sendState.isEnded(a)") { workspace.sendState.isEnded(AgentTarget(session: "a")) }
        try await expectDestination(first.id, .session("a"), "beta 还在线，但挑的是 alpha")
    }

    @Test func 同一个Pi会话重新打开_去处接回新开的那个() async throws {
        let first = try await open("a", in: "/work/alpha", pid: 100)
        let (_, prompt) = try await prompt(in: project)
        workspace.sendState.pick(.session("a"), for: prompt)
        try await end(first)
        try await eventually("workspace.sendState.isEnded(a)") { workspace.sendState.isEnded(AgentTarget(session: "a")) }

        _ = try await open("a", in: "/work/alpha", pid: 200)

        try await eventually("workspace.sendState.isEnded(a) == false") { !workspace.sendState.isEnded(AgentTarget(session: "a")) }
        try await expectDestination(prompt.id, .session("a"))
    }

    @Test func 本次之前就已结束的历史会话不当上次的去处() async throws {
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "old", state: .ended, title: "old", folder: "work", projectID: project.id,
            times: PiTimes(stateSince: .now.addingTimeInterval(-3_600), busySince: nil))
        let (_, first) = try await prompt(in: project)
        try await store.linkCard(first.id, toSession: "old")
        await quietPeriod(.milliseconds(300))

        try await expectDestination(first.id, .newSession)
    }
}
#endif
