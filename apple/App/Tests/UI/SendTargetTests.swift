#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 上"发给哪个 Agent 会话"：提示词的发送钮、右键菜单与会话菜单读同一个 `Workspace.agentTarget`。
/// 会话结束后目标不悄悄换掉，而是写明"已结束"（发不出去，点开改选）；同一个 Pi 会话重新打开了就接回新开的那个。
@MainActor
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
        Task { try await services.consumePiChanges(changes) }
        rig.services.startLiveSessions()
    }

    /// 一个连着桥的 Pi 会话（同一个会话重新打开时 `pid` 不同）。
    private func open(_ sessionID: String, in directory: String, pid: Int32 = 100) async throws -> FakeExtension {
        let ext = FakeExtension(directory: rig.socketDirectory, sessionID: sessionID, pid: pid, options: .init(cwd: directory))
        try ext.start()
        opened.extensions.append(ext)
        await eventually { rig.pi.session(id: ext.id) != nil }
        #expect(rig.pi.session(id: ext.id) != nil)
        await workspace.refreshSessionProjects()
        return ext
    }

    private func end(_ ext: FakeExtension) async {
        ext.close(bye: "quit")
        await eventually { rig.pi.session(id: ext.id) == nil }
        await workspace.refreshSessionProjects()
    }

    /// 选定这个会话为发送目标（菜单里点一下它）。
    private func choose(_ ext: FakeExtension) {
        workspace.sendChoice = AgentTarget(session: ext.sessionID)
    }

    /// 等目标成为 `name`（`ended` 为是否已结束）：状态经桥、同步记录、观察流一路过来，没有更细的信号。
    private func expectTarget(_ project: Project, _ name: String, ended: Bool, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
        await eventually {
            guard let target = workspace.agentTarget(for: project.id) else { return false }
            return workspace.sessionName(target.session) == name && workspace.isEnded(target) == ended
        }
        let target = workspace.agentTarget(for: project.id)
        let detail = "target=\(String(describing: target)) live=\(rig.pi.sessions.map(\.id)) projects=\(workspace.sessionProjects)"
        #expect(target.map { workspace.sessionName($0.session) } == name, Comment(rawValue: detail), sourceLocation: sourceLocation)
        #expect(target.map(workspace.isEnded) == ended, Comment(rawValue: detail), sourceLocation: sourceLocation)
    }

    @Test func 本项目的在线会话是默认目标_按工作目录归入() async throws {
        _ = try await open("a", in: "/work/alpha")
        _ = try await open("o", in: "/other/omega")

        await expectTarget(project, "alpha", ended: false)
        await expectTarget(other, "omega", ended: false)
    }

    @Test func 会话结束后目标写明已结束_发送时在后台唤醒它() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        await expectTarget(project, "alpha", ended: false)
        let folder = rig.directory.appending(path: "work/alpha", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "/sessions/--work-alpha--/a.jsonl"
        try await store.upsertPiSession(PiSession(id: "a", path: file, cwd: folder.path, title: "alpha", lastActivityAt: .now), host: TestApp.hostID)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }

        await end(alpha)

        await expectTarget(project, "alpha", ended: true)
        let target = try #require(workspace.agentTarget(for: project.id))
        #expect(workspace.action(for: target) == "唤醒 Agent 会话「alpha」并发送")
        #expect(workspace.endedTargets.map(\.sessionID) == ["a"], "菜单里列的就是这一批")
        #expect(await workspace.send("接着做", to: target))

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.target == SendTarget(kind: .piSession, name: "alpha", ref: "a") && request.mode == .known(.send))
        #expect(rig.host.calls == [.resume(sessionFile: file, directory: folder.path)])
        #expect(rig.host.extensions["a"]?.messages == [PiMessage(text: "接着做", deliveryID: request.id.uuidString)])
        await expectTarget(project, "alpha", ended: false, "唤醒后它又在线了")
        #expect(workspace.endedTargets.isEmpty)
    }

    @Test func 唤醒不了_会话文件不在这台Mac上_发送失败不假成功() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        await end(alpha)
        await expectTarget(project, "alpha", ended: true)
        let target = try #require(workspace.agentTarget(for: project.id))

        #expect(await workspace.send("接着做", to: target) == false)

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.status == .known(.failed))
        #expect(rig.host.calls.isEmpty)
    }

    /// 别的 Mac 上在线的会话（同步记录里 hostID 不是本机）：与本机的会话一样是提示词的发送目标。
    private func remoteSession(_ id: String, title: String, in project: Project, state: PiWorkState = .settled) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: id, state: state, title: title, folder: title, projectID: project.id)
    }

    @Test func 别的Mac上的在线会话也是发送目标() async throws {
        try await remoteSession("r", title: "atlas", in: project)

        await expectTarget(project, "atlas", ended: false)
    }

    @Test func 发给别的Mac上的会话_写一条指定那台Mac的投送请求_本机不执行() async throws {
        try await remoteSession("r", title: "atlas", in: project)
        await expectTarget(project, "atlas", ended: false)
        let target = try #require(workspace.agentTarget(for: project.id))

        #expect(await workspace.send("接着做", to: target))

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.send))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "r"))
        #expect(rig.host.calls.isEmpty && rig.pi.sessions.isEmpty, "本机没有执行它")
        #expect(workspace.sendChoice == AgentTarget(session: "r"))
    }

    @Test func 别的Mac上的会话正忙_先问马上说还是等它做完再说() async throws {
        try await remoteSession("r", title: "atlas", in: project, state: .thinking)
        await expectTarget(project, "atlas", ended: false)
        let target = try #require(workspace.agentTarget(for: project.id))

        #expect(await workspace.send("看一下", to: target) == false)
        #expect(workspace.busySend?.session == "r")
        #expect(try await store.deliveryRequests().isEmpty)

        workspace.resolveBusySend(.steer)
        await eventually { true }
        for _ in 0..<100 where try await store.deliveryRequests().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.steer))
    }

    @Test func 本机和别的Mac都有会话_本机的会话是默认目标() async throws {
        try await remoteSession("r", title: "atlas", in: project)
        _ = try await open("a", in: "/work/alpha")

        await expectTarget(project, "alpha", ended: false)
    }

    /// Mac 的发送目标、会话菜单与手机的交给 Agent 输入框列的是同一批在线会话。
    @Test func 会话菜单与手机的目标列表是同一批() async throws {
        _ = try await open("a", in: "/work/alpha")
        _ = try await open("b", in: "/work/beta")
        try await remoteSession("r", title: "atlas", in: project)
        try await remoteSession("gone", title: "old", in: project, state: .ended)
        await eventually { workspace.onlineTargets(for: project.id).count == 3 }

        let mac = workspace.onlineTargets(for: project.id).map(\.state.sessionID)
        let phone = HandOffTargets.sessions(rig.services.liveSessions.live, project: project.id).map(\.state.sessionID)

        #expect(mac == phone && Set(mac) == ["a", "b", "r"])
        #expect(workspace.endedTargets.isEmpty, "别的 Mac 上结束的不是本机刚结束的")
    }

    /// 同步记录里还写着"在线"的本机会话，桥上却已经没有了（还没来得及标成结束）：不是能交给的会话，菜单不列、也不当默认目标；
    /// 与发送走的路（已结束）是同一个判定。
    @Test func 本机记录里在线但桥上已没有的会话不列() async throws {
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "stale", state: .settled, title: "stale", folder: "stale", projectID: project.id)
        await eventually { rig.services.liveSessions.live.map(\.state.sessionID) == ["stale"] }
        #expect(rig.services.liveSessions.live.count == 1, "记录读到了")

        #expect(workspace.onlineTargets(for: project.id).isEmpty)
        #expect(workspace.agentTarget(for: project.id) == nil)
        if case .ended = workspace.route(of: "stale") {} else { Issue.record("发送时它是已结束的会话") }
    }

    @Test func 选过的会话结束了也不换成别的() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        _ = try await open("b", in: "/work/beta")
        choose(alpha)
        await expectTarget(project, "alpha", ended: false)

        await end(alpha)

        await expectTarget(project, "alpha", ended: true, "beta 还在线，但用户选的是 alpha")
    }

    @Test func 同一个Pi会话重新打开_目标接回新开的那个() async throws {
        let first = try await open("a", in: "/work/alpha", pid: 100)
        choose(first)
        await end(first)
        await expectTarget(project, "alpha", ended: true)

        _ = try await open("a", in: "/work/alpha", pid: 200)

        await expectTarget(project, "alpha", ended: false)
    }

    @Test func 没有选过时_在线的优先_都结束了取最后结束的那个() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        let beta = try await open("b", in: "/work/beta")
        await end(alpha)
        await expectTarget(project, "beta", ended: false, "beta 还在线")

        await end(beta)
        await expectTarget(project, "beta", ended: true, "最后结束的是 beta")
    }

    @Test func 本次之前就已结束的历史会话不当目标() async throws {
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "old", state: .ended, title: "old", folder: "work", projectID: project.id,
            times: PiTimes(stateSince: .now.addingTimeInterval(-3_600), busySince: nil))
        try await Task.sleep(for: .milliseconds(300))

        #expect(workspace.agentTarget(for: project.id) == nil)
    }

    @Test func 别的项目的结束会话不当目标() async throws {
        let omega = try await open("o", in: "/other/omega")
        await end(omega)

        await expectTarget(other, "omega", ended: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(workspace.agentTarget(for: project.id) == nil)
    }
}
#endif
