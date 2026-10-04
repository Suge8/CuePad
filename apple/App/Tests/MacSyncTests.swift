#if os(macOS)
import CueDispatch
import CueStore
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

        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.state == .known(work))
        #expect(stored.detail == detail)
        #expect(stored.sessionID == "s1")
        #expect(stored.hostID == TestApp.hostID)
    }

    @Test func 会话按工作目录归入项目_结束后记录保留为已结束() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory("/work", for: project.id)

        try await services.consumePiChanges(changes([.appeared(session("s1", cwd: "/work/app"))]))
        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.projectID == project.id)
        #expect(stored.title == "app")

        try await services.consumePiChanges(changes([.ended(session("s1"), reason: .disconnected)]))
        #expect(try await services.store.piSessionStates().map(\.state) == [.known(.ended)])
    }

    @Test func 会话的计时基准原样写进同步记录() async throws {
        var working = session("s1", state: .tool(name: "bash", running: ["bash"]))
        working.stateSince = Date(timeIntervalSince1970: 1_000)
        working.busySince = Date(timeIntervalSince1970: 1_000)
        try await services.consumePiChanges(changes([.appeared(working)]))
        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.stateSince == working.stateSince && stored.busySince == working.busySince)
    }

    @Test func 子代理摘要在会话自己没有说明时写进说明() async throws {
        var master = session("s1", state: .done(aborted: false))
        master.subagents = [PiSubagent(name: "ui", kind: "thinking"), PiSubagent(name: "core", kind: "idle")]
        try await services.consumePiChanges(changes([.appeared(master)]))
        #expect(try await services.store.piSessionStates().first?.detail == "子代理：ui 工作中 · core 空闲")

        var busy = master
        busy.state = .tool(name: "bash", running: ["bash"], detail: "swift test")
        try await services.consumePiChanges(changes([.stateChanged(busy, from: master.state)]))
        #expect(try await services.store.piSessionStates().first?.detail == "bash · swift test")
    }

    @Test func 会话近况写进同步记录() async throws {
        var asked = session("s1", state: .waitingUser(kind: "select", title: "选哪个？"))
        asked.lastPrompt = "修好登录"
        asked.lastReply = "改好了"
        asked.question = "选哪个？\nA\nB"
        try await services.consumePiChanges(changes([.appeared(asked), .infoChanged(asked)]))

        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.lastPrompt == "修好登录" && stored.lastReply == "改好了" && stored.question == "选哪个？\nA\nB")
    }

    @Test func 会话显示名写进同步记录_改名后跟上() async throws {
        var named = session("s1", cwd: "/work/app")
        try await services.consumePiChanges(changes([.appeared(named)]))
        #expect(try await services.store.piSessionStates().first?.title == "app")  // 没有名字和消息时是文件夹名

        named.name = "登录修复"
        try await services.consumePiChanges(changes([.infoChanged(named)]))
        #expect(try await services.store.piSessionStates().first?.title == "登录修复")
    }

    @Test func 启动时把这台Mac遗留的记录标为已结束_不动别的Mac() async throws {
        let mine = PiStateRecorder(store: services.store, hostID: TestApp.hostID)
        let other = PiStateRecorder(store: services.store, hostID: "mac-other")
        try await mine.update(sessionID: "old", state: .thinking)
        try await other.update(sessionID: "theirs", state: .thinking)

        try await services.resetPiState()

        let states = Dictionary(uniqueKeysWithValues: try await services.store.piSessionStates().map { ($0.sessionID, $0.state) })
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
