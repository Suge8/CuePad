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
        let workspace = workspace
        Task { await workspace.observeSessionRecaps() }
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

    @Test func 会话结束后目标写明已结束_发不出去() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        await expectTarget(project, "alpha", ended: false)

        await end(alpha)

        await expectTarget(project, "alpha", ended: true)
        let target = try #require(workspace.agentTarget(for: project.id))
        #expect(workspace.action(for: target) == "发给 Agent 会话「alpha」")
        #expect(await workspace.send("hi", to: target) == false)  // 发不出去：会话已不在桥上
        #expect(try await store.deliveryRequests().isEmpty)
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
        let fresh = Workspace(services: rig.services)
        Task { await fresh.observeSessionRecaps() }
        await fresh.refreshSessionProjects()
        try await Task.sleep(for: .milliseconds(300))

        #expect(fresh.agentTarget(for: project.id) == nil)
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
