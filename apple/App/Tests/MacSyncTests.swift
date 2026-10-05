#if os(macOS)
import CueDispatch
import CueStore
import CueSync
import Foundation
import Testing
import AppKit
@testable import CuePad
@testable import CuePi

/// Mac 端的同步职责：唤醒时同步；把 Pi 会话状态写成同步记录；执行手机发来的投送请求。
@MainActor
struct MacSyncTests {
    let rig = TestApp()
    var services: AppServices { rig.services }

    private func session(
        _ sessionID: String, cwd: String = "/work/app", state: PiAgentState = .thinking, pid: Int32 = 100
    ) -> CuePi.PiSession {
        CuePi.PiSession(
            id: "\(sessionID).\(pid)", sessionID: sessionID, sessionFile: nil, pid: pid, cwd: URL(filePath: cwd, directoryHint: .isDirectory),
            mode: "tui", model: nil, terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version, state: state, stateSince: .now)
    }

    private func changes(_ items: [PiSessionChange]) -> AsyncStream<PiSessionChange> {
        AsyncStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: 退出

    /// 退出可能发生在主线程被占住时：在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等收尾的回复，
    /// 主线程上排队的任务轮不到。收尾的等待部分若需要主线程，退出就永远等不到。
    @Test(.timeLimit(.minutes(1)))
    func 主线程被占住时退出收尾仍在上限内完成() async throws {
        services.startSync()
        try await services.startDeliveryExecutor()
        await eventually { rig.sync.started == 1 }

        let finish = services.beginShutdown(within: .seconds(2))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await finish()
            done.signal()
        }
        #expect(Self.blockCurrentThread(until: done, seconds: 3), "主线程被占住时收尾等不到")
        #expect(rig.sync.stopped == 1)
    }

    /// 同步地占住当前（主）线程，直到信号或超时。
    private nonisolated static func blockCurrentThread(until signal: DispatchSemaphore, seconds: Double) -> Bool {
        signal.wait(timeout: .now() + seconds) == .success
    }

    @Test(.timeLimit(.minutes(1)))
    func 退出收尾有上限_组件卡住时到点放行并指出是哪个() async throws {
        services.startSync()
        await eventually { rig.sync.started == 1 }
        rig.sync.stopHangs.withLock { $0 = true }

        let late = await services.stop(within: .milliseconds(200))

        #expect(late == "同步引擎")
        #expect(rig.sync.stopped == 1)
    }

    @Test func 退出时停止同步引擎与远程投送执行器() async throws {
        services.startSync()
        try await services.startDeliveryExecutor()
        await eventually { rig.sync.started == 1 }

        await services.stop()

        #expect(rig.sync.stopped == 1)
        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .clipboard, name: "剪贴板"), on: TestApp.hostID)
        // 停止后不再有观察者领取：没有事件可等，给执行器足够的时间再确认仍未处理
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await services.store.deliveryRequest(request.id)?.status == .known(.pending))
        #expect(rig.channels.calls.isEmpty)
    }

    // MARK: 唤醒

    @Test func 系统唤醒时立即同步() async {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        await eventually { rig.sync.started == 1 }

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        await eventually { rig.sync.syncNows == 1 }
        #expect(rig.sync.syncNows == 1)
    }

    // MARK: Pi 状态记录

    @Test(arguments: [
        (PiAgentState.idle, PiWorkState.settled, String?.none),
        (.thinking, .thinking, nil),
        (.outputting, .outputting, nil),
        (.tool(name: "bash", running: ["bash"], detail: nil), .tool, "bash"),
        (.tool(name: "read", running: ["read"], detail: "README.md"), .tool, "read · README.md"),
        (.waitingUser(kind: "confirm", title: "覆盖文件？"), .waitingForUser, "覆盖文件？"),
        (.done(aborted: false), .settled, nil),
        (.error(message: #"429 {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#), .error, "请求太频繁，稍后再试：slow down"),
    ])
    func Pi状态映射成同步记录的状态与说明(agent: PiAgentState, work: PiWorkState, detail: String?) async throws {
        try await services.consumePiChanges(changes([.appeared(session("s1", state: agent))]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.state == .known(work))
        #expect(stored.detail == detail)
        #expect(stored.sessionID == "s1")
        #expect(stored.hostID == TestApp.hostID)
    }

    @Test func 会话按工作目录归入项目_结束后记录保留为已结束() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory("/work", for: project.id)

        try await services.consumePiChanges(changes([.appeared(session("s1", cwd: "/work/app"))]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.projectID == project.id)
        #expect(stored.title == "app")

        try await services.consumePiChanges(changes([.ended(session("s1"), reason: .disconnected)]))
        #expect(try await services.store.allPiSessionStates().map(\.state) == [.known(.ended)])
    }

    @Test func 会话的计时基准原样写进同步记录() async throws {
        var working = session("s1", state: .tool(name: "bash", running: ["bash"]))
        working.stateSince = Date(timeIntervalSince1970: 1_000)
        working.busySince = Date(timeIntervalSince1970: 1_000)
        try await services.consumePiChanges(changes([.appeared(working)]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.stateSince == working.stateSince && stored.busySince == working.busySince)
    }

    /// 子代理写成结构化列表（名字与此刻在干什么），一行一个；说明栏只写会话自己的说明。
    @Test func 子代理写成结构化列表() async throws {
        var master = session("s1", state: .delegating)
        master.subagents = [PiSubagent(name: "ui", kind: "thinking"), PiSubagent(name: "core", kind: "error")]
        try await services.consumePiChanges(changes([.appeared(master)]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.subagents == [
            PiSubagentState(name: "ui", activity: .known(.working)), PiSubagentState(name: "core", activity: .known(.error)),
        ])
        #expect(stored.detail == nil)
    }

    @Test func 会话近况写进同步记录() async throws {
        var asked = session("s1", state: .waitingUser(kind: "select", title: "选哪个？"))
        asked.lastPrompt = "修好登录"
        asked.lastReply = "改好了"
        asked.question = PiPrompt(id: "p-1", kind: "select", text: "选哪个？", options: ["A", "B"])
        try await services.consumePiChanges(changes([.appeared(asked), .infoChanged(asked)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.lastPrompt == "修好登录" && stored.lastReply == "改好了" && stored.question == PiQuestion(promptID: "p-1", kind: .select, text: "选哪个？", options: ["A", "B"]))
    }

    @Test func 会话显示名写进同步记录_改名后跟上() async throws {
        var named = session("s1", cwd: "/work/app")
        try await services.consumePiChanges(changes([.appeared(named)]))
        #expect(try await services.store.allPiSessionStates().first?.title == "app")  // 没有名字和消息时是文件夹名

        named.name = "登录修复"
        try await services.consumePiChanges(changes([.infoChanged(named)]))
        #expect(try await services.store.allPiSessionStates().first?.title == "登录修复")
    }

    @Test func 启动时把这台Mac遗留的记录标为已结束_不动别的Mac() async throws {
        let mine = PiStateRecorder(store: services.store, hostID: TestApp.hostID)
        let other = PiStateRecorder(store: services.store, hostID: "mac-other")
        try await mine.update(sessionID: "old", state: .thinking)
        try await other.update(sessionID: "theirs", state: .thinking)

        try await services.resetPiState()

        let states = Dictionary(uniqueKeysWithValues: try await services.store.allPiSessionStates().map { ($0.sessionID, $0.state) })
        #expect(states == ["old": .known(.ended), "theirs": .known(.thinking)])
    }

    // MARK: 手机发来的投送请求

    private func awaitFinished(_ id: UUID) async throws -> DeliveryRequest {
        let watchdog = Task { try await Task.sleep(for: .seconds(10)); throw CancellationError() }
        defer { watchdog.cancel() }
        for try await request in services.store.observe([.deliveryRequests], { try $0.deliveryRequest(id) }) {
            if let request, request.status == .known(.succeeded) || request.status == .known(.failed) { return request }
        }
        throw CancellationError()
    }

    @Test func 手机的Pi直发请求在这台Mac执行并写回结果() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "做这件事", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .steer)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.send(PiMessage(text: "做这件事", whenBusy: .steer), "sess-1.100")])
        #expect(done.handledBy == TestApp.hostID)
    }

    @Test func 手机的作答请求交给扩展作答_不写发送记录() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: true)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestAnswer(
            PiAnswer(promptID: "p-1", value: .option("覆盖")), to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"),
            on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.answer(.option("覆盖"), "p-1", "sess-1.100")])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// Mac 主动拉取的条件看桥上真的连着的会话，不看资料库里的状态记录（记录可能是没来得及标为结束的旧会话）；
    /// 本机有还没结果的投送请求时也在等。
    @Test(.timeLimit(.minutes(1)))
    func 主动拉取的条件_没有连着的会话时不因旧记录而拉_有本机待执行请求时拉() async throws {
        try await PiStateRecorder(store: services.store, hostID: TestApp.hostID).update(sessionID: "stale", state: .settled, title: "旧会话")
        var waiting = services.pollingCondition().makeAsyncIterator()
        #expect(await waiting.next() == .some(nil))

        _ = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        while let next = await waiting.next(), next == nil {}
        #expect(services.pollingCadence == SyncPoller.Cadence(interval: .seconds(2)))
    }

    @Test func 连接测试请求立即完成_不碰Pi_不写发送记录() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded) && done.mode == .known(.ping))
        #expect(rig.channels.calls.isEmpty)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 写回结果后立即只上传这一条，不等引擎调度：手机才能尽早拉到结果。
    @Test(.timeLimit(.minutes(1)))
    func 执行器写回结果后立即上传这一条() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        #expect(await uploads.next() == request.id.uuidString.lowercased())
        #expect(try await services.store.deliveryRequest(request.id)?.isOpen == false)
    }

    // MARK: 继续会话、开新会话

    private func launched(_ launch: PiLaunch, title: String = "app") async throws -> DeliveryRequest {
        try await services.startDeliveryExecutor()
        let request = try await services.store.requestLaunch(launch, title: title, on: TestApp.hostID)
        return try await awaitFinished(request.id)
    }

    /// 测试目录里的一个真实文件夹（执行器启动前检查目录存在）。
    private func folder(_ name: String) throws -> URL {
        let url = rig.directory.appending(path: "work/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func indexed(_ id: String, cwd: URL) async throws -> StoredPiSession {
        let session = StoredPiSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd.path, title: "修好登录", lastActivityAt: .now)
        try await services.store.upsertPiSession(session, host: TestApp.hostID)
        return session
    }

    @Test func 给已结束的会话发消息_后台恢复后送达() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "接着做", to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.channels.calls == [.send(PiMessage(text: "接着做"), "s1.900")])
    }

    @Test func 新会话_后台开在项目目录_开场的话送入() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }

        let done = try await launched(PiLaunch(place: .project(project.id), prompt: "看看测试为什么挂", token: "tok-1"), title: "App")

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.open(directory: directory.path, launchToken: "tok-1")])
        #expect(rig.channels.calls == [.send(PiMessage(text: "看看测试为什么挂"), "new-tok-1.900")])
    }

    @Test func 新会话_与某会话同目录_没有开场的话就不发_项目没有目录时失败() async throws {
        let other = try folder("other")
        _ = try await indexed("s1", cwd: other)
        let bare = try await services.store.createProject(name: "无目录", color: "#000000")
        defer { services.cancelBackgroundWork() }

        let beside = try await launched(PiLaunch(place: .besideSession("s1"), prompt: nil, token: "tok-2"))
        #expect(beside.status == .known(.succeeded))
        #expect(rig.host.calls == [.open(directory: other.path, launchToken: "tok-2")])
        #expect(rig.channels.calls.isEmpty)

        let noDirectory = try await launched(PiLaunch(place: .project(bare.id), prompt: nil, token: "tok-3"), title: "无目录")
        #expect(noDirectory.status == .known(.failed))
        #expect(noDirectory.resultDetail == SendError.noCodeDirectory("无目录").localizedDescription)
    }

    /// 目录被删或改名了：不启动 Pi，按失败写回，原因写目录末段名。
    @Test func 目录不存在时不启动_按失败写回() async throws {
        _ = try await indexed("s1", cwd: rig.directory.appending(path: "work/gone", directoryHint: .isDirectory))
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(rig.directory.appending(path: "work/moved").path, for: project.id)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let send = try await services.store.requestDelivery(
            "接着做", to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let resumed = try await awaitFinished(send.id)
        #expect(resumed.status == .known(.failed) && resumed.resultDetail == "目录不存在：gone")
        let start = try await launched(PiLaunch(place: .project(project.id), prompt: nil, token: "tok-4"), title: "App")
        #expect(start.status == .known(.failed) && start.resultDetail == "目录不存在：moved")
        #expect(rig.host.calls.isEmpty)
    }

    /// 后台托管着时，用户在自己的终端里打开了同一个会话：同步记录跟着用户那个进程（不再标"后台托管"），
    /// 后台进程随后退出也不把记录标为已结束——始终只有一条。
    @Test func 同一会话换到用户的终端里_记录跟着新进程_后台进程退出不结束记录() async throws {
        var hosted = session("s1", pid: 100)
        hosted.hosted = true
        var mine = session("s1", pid: 200)
        mine.state = .tool(name: "bash", running: ["bash"])
        try await services.consumePiChanges(changes([
            .appeared(hosted), .appeared(mine), .stateChanged(hosted, from: .thinking), .ended(hosted, reason: .closed(reason: "quit")),
        ]))

        let records = try await services.store.allPiSessionStates()
        #expect(records.count == 1)
        #expect(records.first?.hosted == false && records.first?.state == .known(.tool))
    }

    @Test func 新会话的认领标识写进同步记录() async throws {
        var started = session("s9")
        started.launchToken = "tok-9"
        try await services.consumePiChanges(changes([.appeared(started)]))
        #expect(try await services.store.piSessionPage(PiSessionQuery(launchToken: "tok-9")).items.map(\.state.sessionID) == ["s9"])
    }

    /// 项目在哪台 Mac 上绑定了目录（只带目录末段名）同步给手机：Mac 绑定、解绑后随之写、删。
    @Test(.timeLimit(.minutes(1)))
    func 目录绑定随绑定与解绑同步() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.startDirectoryBindings()
        defer { services.cancelBackgroundWork() }

        try await services.store.setDirectory("/Users/someone/work/app", for: project.id)
        var bound: [DirectoryBinding] = []
        for try await bindings in services.store.observe([.directoryBindings], { try $0.directoryBindings() }) where !bindings.isEmpty {
            bound = bindings
            break
        }
        #expect(bound.map(\.projectID) == [project.id] && bound.map(\.hostID) == [TestApp.hostID] && bound.map(\.folder) == ["app"])

        try await services.store.setDirectory(nil, for: project.id)
        for try await bindings in services.store.observe([.directoryBindings], { try $0.directoryBindings() }) where bindings.isEmpty { break }
    }

    @Test func 手机的放进输入框请求只粘贴文字() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "草稿", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .paste)
        _ = try await awaitFinished(request.id)

        #expect(rig.channels.calls == [.paste("草稿", "sess-1.100")])
    }

    @Test func 目标会话已结束时请求失败并说明原因() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "gone", ref: "sess-gone"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(done.resultDetail?.contains("会话") == true)
        #expect(rig.channels.calls.isEmpty)
    }

    @Test func 通用投送请求按bundle投送_失败原因可读() async throws {
        rig.channels.dispatchError = DispatchError.accessibilityRequired
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .app, name: "Ghostty", ref: "com.mitchellh.ghostty"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(rig.channels.calls.contains(.dispatch(Payload(text: "hi"), .bundleID("com.mitchellh.ghostty"), submit: false)))
        #expect(done.status == .known(.failed))
        #expect(done.resultDetail == DispatchError.accessibilityRequired.localizedDescription, "写回的是错误自身的说明")
    }

    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        let first = HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001")
        #expect(first == HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001"))
        #expect(first != HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000002"))
        #expect(first.hasPrefix("mac-") && !first.contains("A1B2C3D4"))
    }
}
#endif
