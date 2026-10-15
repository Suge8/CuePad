#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 上"开始"一件任务（`Workspace.handOff`）：标题连同正文作为第一句交出去——上一步绑着会话就接着发进那个会话，没有就在项目文件夹开一个以任务命名的新会话并绑上。
/// 会话结束了在后台唤醒它，会话正忙先问怎么说，别的 Mac 上的会话写指定那台 Mac 的请求；送达后这一步绑上会话，正文留在任务上。
struct SendTargetTests {
    let rig = TestApp()
    let workspace: Workspace
    let project: Project
    private var store: CueStore { rig.services.store }
    /// 假扩展一释放连接就断开（会话就结束了），所以连着的都留在这里，直到测试结束。
    private let opened = Opened()
    private final class Opened { var extensions: [FakeExtension] = [] }

    init() async throws {
        project = try await rig.services.store.createProject(name: "Work", color: "blue")
        try await rig.services.store.setDirectory("/work", for: project.id)
        try await rig.offersPi()
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
        return ext
    }

    private func end(_ ext: FakeExtension) async throws {
        ext.close(bye: "quit")
        try await eventually("rig.pi.session(id: ext.id) == nil") { rig.pi.session(id: ext.id) == nil }
    }

    /// 一个带着正文的叶子任务；`session` 给了就是上一步绑着这个会话的第二步（开始时接着用它）。
    private func leaf(in project: Project?, session: String? = nil) async throws -> Card {
        guard let session else { return try await store.createTask(Self.text, in: project?.id) }
        let task = try await store.createTask("修乱序", in: project?.id)
        let first = try await store.createTask("复现", under: task.id)
        try await store.linkCard(first.id, toSession: session)
        return try await store.createTask(Self.text, under: task.id)
    }

    private static let text = "修乱序\n按首次加入时间排"

    /// 别的 Mac 上在线的会话（同步记录里 hostID 不是本机）。
    private func remoteSession(_ id: String, title: String, state: PiWorkState = .settled) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: id, state: state, title: title, directory: title, projectID: project.id)
    }

    @Test func 没有会话可接着用_开始时在项目文件夹开以任务命名的新会话并绑上_正文留着() async throws {
        let folder = rig.directory.appending(path: "work/new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await store.setDirectory(folder.path, for: project.id)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let task = try await leaf(in: project)

        workspace.handOff(task)

        try await eventually("rig.host.calls 里有在项目文件夹打开") { !rig.host.calls.isEmpty }
        guard case .open(let directory, let token, _, _, _) = try #require(rig.host.calls.first) else {
            Issue.record("没有开新会话")
            return
        }
        #expect(directory == folder.path)
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.mode == .known(.start) && request.target.name == "修乱序" && request.launch?.prompt == Self.text)

        // 会话开好、带着认领标识记下：任务绑上它
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "new", state: .thinking, title: "修乱序", launchToken: token)
        let bound = try #require(try await store.card(task.id))
        #expect(bound.piSessionID == "new" && bound.status == .inProgress && bound.body == Self.text)
    }

    @Test func 没有文件夹的未分类任务_开不了会话_什么都不写() async throws {
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let task = try await leaf(in: nil)

        workspace.handOff(task)

        try await eventually("workspace.notice != nil") { workspace.notice != nil }
        #expect(workspace.notice?.isError == true && rig.host.calls.isEmpty)
        #expect(try await store.deliveryRequests().isEmpty)
    }

    @Test func 上一步绑着会话_开始时接着发进那个会话_送达后这一步绑上_不开新会话() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let task = try await leaf(in: project, session: "a")

        workspace.handOff(task)

        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "a" }
        #expect(alpha.messages.map(\.text) == [Self.text])
        #expect(try await store.card(task.id)?.body == Self.text)
        #expect(rig.host.calls.isEmpty)
    }

    @Test func 上一步的会话结束了_开始时在后台唤醒它() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        let task = try await leaf(in: project, session: "a")
        let folder = rig.directory.appending(path: "work/alpha", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "/sessions/--work-alpha--/a.jsonl"
        try await store.upsertPiSession(IndexedSession(id: "a", path: file, cwd: folder.path, title: "alpha", lastActivityAt: .now), host: TestApp.hostID)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        try await end(alpha)

        workspace.handOff(task)

        try await eventually("唤醒后话送到") { rig.host.extensions["a"]?.messages.isEmpty == false }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.target == SendTarget(kind: .piSession, name: "alpha", ref: "a") && request.mode == .known(.send))
        #expect(rig.host.calls == [.resume(sessionFile: file, directory: folder.path)])
        #expect(rig.host.extensions["a"]?.messages == [PiMessage(text: Self.text, deliveryID: request.id.uuidString)])
        // 交出就提示，不等送达
        #expect(workspace.notice?.text == Dotted("已交给 Agent 会话「alpha」", "唤醒后送达"))
        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "a" }
    }

    @Test func 唤醒不了_会话文件不在这台Mac上_没送到_这一步不绑会话() async throws {
        let alpha = try await open("a", in: "/work/alpha")
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let task = try await leaf(in: project, session: "a")
        try await end(alpha)

        workspace.handOff(task)

        let request = try #require(try await eventually(store, { try $0.deliveryRequests().first }) { $0?.isOpen == false })
        #expect(request.status == .known(.failed) && request.cardID == task.id)
        #expect(rig.host.calls.isEmpty)
        #expect(try await store.card(task.id)?.piSessionID == nil)
    }

    @Test func 上一步的会话重新打开了_直接发进新开的那个() async throws {
        let first = try await open("a", in: "/work/alpha", pid: 100)
        try await rig.services.executor.start()
        defer { rig.services.cancelBackgroundWork() }
        let task = try await leaf(in: project, session: "a")
        try await end(first)
        let again = try await open("a", in: "/work/alpha", pid: 200)

        workspace.handOff(task)

        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "a" }
        #expect(again.messages.map(\.text) == [Self.text] && first.messages.isEmpty)
        #expect(rig.host.calls.isEmpty, "没有当成已结束的去唤醒")
    }

    @Test func 上一步绑着别的Mac上的会话_写一条指定那台Mac的投送请求_本机不执行() async throws {
        try await remoteSession("r", title: "atlas")
        let task = try await leaf(in: project, session: "r")
        try await eventually("liveSessions.live == [r]") { rig.services.liveSessions.live.map(\.state.sessionID) == ["r"] }

        workspace.handOff(task)

        _ = try await eventually(store, { try $0.deliveryRequests().count }) { $0 > 0 }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.send))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "r"))
        #expect(rig.host.calls.isEmpty && rig.pi.sessions.isEmpty, "本机没有执行它")
        #expect(try await store.card(task.id)?.piSessionID == nil, "还没送达，这一步还没绑上")
    }

    @Test func 会话正忙_先问马上说还是等它做完再说() async throws {
        try await remoteSession("r", title: "atlas", state: .thinking)
        let task = try await leaf(in: project, session: "r")
        try await eventually("liveSessions.live == [r]") { rig.services.liveSessions.live.map(\.state.sessionID) == ["r"] }

        workspace.handOff(task)
        try await eventually("workspace.sendState.busy?.session == r") { workspace.sendState.busy?.session == "r" }
        #expect(try await store.deliveryRequests().isEmpty)

        workspace.resolveBusySend(.steer)
        _ = try await eventually(store, { try $0.deliveryRequests().count }) { $0 > 0 }
        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.hostID == "mac-b" && request.mode == .known(.steer))
    }

    /// 交到哪只有一份规则（`CueStore.handOffPlan`）：同样的一步，Mac 上"开始"与 Cue 开工落到同一个会话；开新会话时会话名、项目、哪台 Mac 都一样。
    @Test func Mac开始与Cue开工_交到同一个地方() async throws {
        try await remoteSession("r", title: "atlas")
        let (forMac, forCue) = (try await leaf(in: project, session: "r"), try await leaf(in: project, session: "r"))
        try await eventually("liveSessions.live == [r]") { rig.services.liveSessions.live.map(\.state.sessionID) == ["r"] }
        workspace.handOff(forMac)
        let mac = try await eventually(store, { try $0.deliveryRequests().first }) { $0 != nil }!
        let cue = try await store.startLeaf(forCue.id, host: TestApp.hostID, cue: true)
        #expect(cue.target.ref == "r" && mac.target.ref == "r" && cue.hostID == mac.hostID)

        // 上一步绑着别的 Mac 上已结束的会话：都请那台 Mac 唤醒它
        try await remoteSession("gone", title: "relic", state: .ended)
        let (endedForMac, endedForCue) = (try await leaf(in: project, session: "gone"), try await leaf(in: project, session: "gone"))
        workspace.handOff(endedForMac)
        let macWake = try await eventually(store, { try $0.deliveryRequests().first { $0.target.ref == "gone" } }) { $0 != nil }!
        let cueWake = try await store.startLeaf(endedForCue.id, host: TestApp.hostID, cue: true)
        #expect(macWake.hostID == "mac-b" && cueWake.hostID == "mac-b" && cueWake.target.ref == "gone")

        let fresh = try await leaf(in: project)
        let cueLaunch = try await store.startLeaf(fresh.id, host: TestApp.hostID, cue: true)
        #expect(try await store.withdrawDelivery(cueLaunch.id))
        workspace.handOff(fresh)
        let macLaunch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }!
        #expect(macLaunch.launch?.name == "修乱序" && cueLaunch.launch?.name == "修乱序")
        #expect(macLaunch.launch?.project == cueLaunch.launch?.project && macLaunch.hostID == cueLaunch.hostID)
        #expect(macLaunch.target.name == cueLaunch.target.name)
    }

    /// 同步记录里还写着"在线"的本机会话，桥上却已经没有了（还没来得及标成结束）：不是能绑、能交的在线会话，与发送走的路（已结束）是同一个判定。
    @Test func 本机记录里在线但桥上已没有的会话不算在线() async throws {
        _ = try await open("a", in: "/work/alpha")
        try await remoteSession("r", title: "atlas")
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "stale", state: .settled, title: "stale", directory: "stale", projectID: project.id)
        try await eventually("liveSessions.live 有三条") { rig.services.liveSessions.live.count == 3 }

        #expect(Set(workspace.sendState.onlineTargets(for: project.id).map(\.state.sessionID)) == ["a", "r"])
        if case .ended = workspace.sendState.route(of: "stale") {} else { Issue.record("发送时它是已结束的会话") }
    }
}
#endif
