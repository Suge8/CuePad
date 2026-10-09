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
            mode: "tui", terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version, state: state, stateSince: .now)
    }

    private func changes(_ items: [PiSessionChange]) -> AsyncStream<PiSessionChange> {
        AsyncStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: 发到手机的预览

    /// Pi 里的 cuepad_show 工具经桥交来的请求：文件进库、记在这个会话名下；页面引用了别的文件时把缺的告诉 Agent（让它改成单文件再发）；
    /// 拒绝时把原因原样交回，工具据此报错。
    @Test func 工具请求的文件进库_页面缺的资源提示给Agent_拒绝带原因() async throws {
        #expect(services.pi.showHandler != nil)
        let page = rig.directory.appending(path: "demo.html")
        try Data(#"<link rel="stylesheet" href="style.css"><h1>登录页</h1>"#.utf8).write(to: page)

        let shown = try await services.showPreview(PiShowRequest(path: page.path, title: "登录页"), from: session("s1"))

        let stored = try #require(try await services.store.previews(of: "s1").first)
        #expect(shown.preview == stored.id.uuidString.lowercased() && stored.title == "登录页")
        #expect(shown.note?.contains("style.css") == true)

        let missing = rig.directory.appending(path: "nope.html").path
        await #expect(throws: CueStoreError.previewUnreadable(missing)) {
            try await services.showPreview(PiShowRequest(path: missing, title: nil), from: session("s1"))
        }
        #expect(try await services.store.previews(of: "s1").count == 1)
    }

    /// 给模型看的工具说明写在扩展里（TS），能发什么、多大，必须与 Store 的规则（`PiPreviewKind`、`PiPreview.maxBytes`）一致。
    @Test func 扩展里的工具说明与预览规则一致() {
        let source = PiExtensionBundle.source
        #expect(source.contains(PiPreviewKind.supportedList))
        #expect(source.contains("不超过 \(PiPreview.maxBytes / 1_000_000) MB"))
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
        (.incompatible, .incompatible, nil),
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

    /// 子代理写成结构化列表（名字、角色、状态、在做什么与本次运行的时刻），一行一个；说明栏只写会话自己的说明；
    /// FireCode 以后新增的状态原样留着。
    @Test func 子代理写成结构化列表() async throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let settled = Date(timeIntervalSince1970: 1_300)
        var master = session("s1", state: .delegating)
        master.subagents = [
            PiSubagent(name: "ui", role: "工程师", state: "running", action: "运行 bun test", startedAt: started),
            PiSubagent(name: "core", role: "审查员", state: "failed", action: "超时", startedAt: started, settledAt: settled),
            PiSubagent(name: "docs", role: "写手", state: "napping"),
        ]
        try await services.consumePiChanges(changes([.appeared(master)]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.subagents == [
            PiSubagentState(name: "ui", role: "工程师", phase: .known(.running), action: "运行 bun test", startedAt: started),
            PiSubagentState(name: "core", role: "审查员", phase: .known(.failed), action: "超时", startedAt: started, settledAt: settled),
            PiSubagentState(name: "docs", role: "写手", phase: .unknown("napping")),
        ])
        #expect(stored.detail == nil)
    }

    /// 当前模型、思考强度与可选模型写成同步记录里的结构化字段；Pi 报的新强度（本版本不认识）原样留着。
    @Test func 会话的模型与思考强度和可选模型写进同步记录() async throws {
        let sonnet = PiModel(provider: "anthropic", id: "sonnet", name: "Sonnet", thinkingLevels: ["off", "low"])
        let opus = PiModel(provider: "anthropic", id: "opus", name: "Opus", thinkingLevels: ["off", "high", "ultra"])
        var configured = session("s1")
        configured.model = opus
        configured.thinking = "high"
        configured.availableModels = [sonnet, opus]
        try await services.consumePiChanges(changes([.appeared(configured)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.model == PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.off, .high]))
        #expect(stored.thinking == .known(.high))
        #expect(stored.models.map(\.key.id) == ["sonnet", "opus"])

        configured.thinking = "ultra"
        try await services.consumePiChanges(changes([.infoChanged(configured)]))
        #expect(try await services.store.allPiSessionStates().first?.thinking == .unknown("ultra"))
    }

    /// 上下文余量与斜杠命令清单写成同步记录里的结构化字段（手机据此画圆环、弹命令面板）；Pi 报的本版本不认识的来源原样留着。
    @Test func 会话的上下文余量与命令清单写进同步记录() async throws {
        var reporting = session("s1")
        reporting.context = PiContext(tokens: 42_000, window: 200_000)
        reporting.commands = [
            PiCommand(name: "compact", description: "压缩上下文", source: "builtin", hint: "[说明]"),
            PiCommand(name: "skill:review", description: nil, source: "skill", hint: nil),
            PiCommand(name: "x", description: nil, source: "plugin", hint: nil),
        ]
        try await services.consumePiChanges(changes([.appeared(reporting)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.context == PiContextUsage(tokens: 42_000, window: 200_000))
        #expect(stored.commands == [
            PiSlashCommand(name: "compact", summary: "压缩上下文", source: .known(.builtin), hint: "[说明]"),
            PiSlashCommand(name: "skill:review", summary: nil, source: .known(.skill)),
            PiSlashCommand(name: "x", summary: nil, source: .unknown("plugin")),
        ])
    }

    @Test func 等你回答的弹窗写进同步记录() async throws {
        var asked = session("s1", state: .waitingUser(kind: "select", title: "选哪个？"))
        asked.question = PiPrompt(id: "p-1", kind: "select", text: "选哪个？", options: ["A", "B"])
        try await services.consumePiChanges(changes([.appeared(asked), .infoChanged(asked)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.question == PiQuestion(promptID: "p-1", kind: .select, text: "选哪个？", options: ["A", "B"]))
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

    /// 等请求有结果；10 秒没有就失败并说明（观察流不会自己结束，没有上限会无声挂住整个测试宿主）。
    private func awaitFinished(_ id: UUID) async throws -> DeliveryRequest {
        let store = services.store
        return try await withThrowingTaskGroup(of: DeliveryRequest.self) { group in
            group.addTask {
                for try await request in store.observe([.deliveryRequests], { try $0.deliveryRequest(id) }) {
                    if let request, request.status == .known(.succeeded) || request.status == .known(.failed) { return request }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TimedOut(what: "投送请求 \(id) 没有在 10 秒内出结果")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
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
        // 带上请求 id：扩展写进会话文件里那条消息，对话据此把请求气泡换成它
        #expect(rig.channels.calls == [.send(PiMessage(text: "做这件事", whenBusy: .steer, deliveryID: request.id.uuidString), "sess-1.100")])
        #expect(done.handledBy == TestApp.hostID)
    }

    /// 斜杠命令走桥的命令通道（由 Pi 展开执行，不是当文字发出）；忙时按"等它做完再说"排队，和发出去的话一样记发送记录。
    @Test func 手机的斜杠命令请求交给桥按命令执行() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: true)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "/greet world", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.command("/greet world", .followUp, "sess-1.100")])
        #expect(try await services.store.sendRecords().isEmpty)  // 发送记录只记内容的投送，命令不记
    }

    /// 交给 Agent 时命令带着卡片（卡片文字是参数）：卡片关联到会话、任务进行中，照样不写发送记录。
    @Test func 带卡片的斜杠命令只关联卡片_不写发送记录() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        let task = try await services.store.createTask("改登录", in: nil)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "/greet\n\n改登录", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command, card: task.id)
        _ = try await awaitFinished(request.id)

        let linked = try #require(try await services.store.card(task.id))
        #expect(linked.piSessionID == "sess-1" && linked.status == .inProgress)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 斜杠命令里带图片按失败写回() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        // 图片文件在本机（没到的图片执行器会等它同步过来，那是另一条路径）
        let hash = try services.store.files.store(pngData(shade: 0.3))
        let request = try await services.store.requestDelivery(
            "/greet\n\n![](cuepad://img/\(hash))", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(rig.channels.calls.isEmpty)
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

    @Test func 手机的配置请求交给桥改模型与思考强度_不写发送记录() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: true)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            PiConfig(model: PiModelKey(provider: "anthropic", id: "opus"), thinking: .high),
            to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.configure(PiModelRef(provider: "anthropic", id: "opus"), "high", nil, "sess-1.100")])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 手机的结束请求让会话收尾_不写发送记录() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: true)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestEnd(of: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.end("sess-1.100")])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 已经结束的会话（不在这台 Mac 的桥上）：目标达成，按成功写回，不能为了结束它而把它恢复起来。
    @Test func 结束已经结束的会话直接成功_不恢复() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestEnd(of: SendTarget(kind: .piSession, name: "app", ref: "old"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls.isEmpty)
    }

    @Test func 手机的停止请求让桥中止这一轮_不写发送记录() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: true)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestStop(of: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.abort("sess-1.100")])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 已经结束的会话没有这一轮可停：按成功写回，不恢复它、不碰桥。
    @Test func 停止已经结束的会话直接成功_不恢复() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestStop(of: SendTarget(kind: .piSession, name: "app", ref: "old"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls.isEmpty && rig.channels.calls.isEmpty)
    }

    /// 停止这一轮：请求发给会话所在的 Mac，写出后立即上传。
    @Test(.timeLimit(.minutes(1)))
    func 请求停止写给会话所在的Mac并立即上传() async throws {
        try await PiStateRecorder(store: services.store, hostID: "mac-other").update(sessionID: "far", state: .thinking, title: "远处")
        let session = try #require(try await services.store.allPiSessionStates().first)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        let request = try await services.stop(session)

        #expect(request.hostID == "mac-other" && request.mode == .known(.stop) && request.target.ref == "far")
        #expect(await uploads.next() == request.id.uuidString.lowercased())
    }

    /// 手机上结束会话：请求发给会话所在的 Mac，写出后立即上传。
    @Test(.timeLimit(.minutes(1)))
    func 请求结束会话写给会话所在的Mac并立即上传() async throws {
        try await PiStateRecorder(store: services.store, hostID: "mac-other").update(sessionID: "far", state: .settled, title: "远处")
        let session = try #require(try await services.store.allPiSessionStates().first)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        let request = try await services.end(session)

        #expect(request.hostID == "mac-other" && request.mode == .known(.end) && request.target.ref == "far")
        #expect(await uploads.next() == request.id.uuidString.lowercased())
    }

    /// 手机上改配置：请求发给会话所在的那台 Mac，写出后立即上传（与发送、作答同一条通路）。
    @Test(.timeLimit(.minutes(1)))
    func 请求改配置写给会话所在的Mac并立即上传() async throws {
        try await PiStateRecorder(store: services.store, hostID: "mac-other").update(sessionID: "far", state: .settled, title: "远处")
        let session = try #require(try await services.store.allPiSessionStates().first)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        let request = try await services.configure(PiConfig(thinking: .low), for: session)

        #expect(request.hostID == "mac-other" && request.config == PiConfig(thinking: .low) && request.target.ref == "far")
        #expect(await uploads.next() == request.id.uuidString.lowercased())
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

    // MARK: 后台恢复、开新会话

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
        #expect(rig.channels.calls == [.send(PiMessage(text: "接着做", deliveryID: request.id.uuidString), "s1.900")])
    }

    /// 改名是会话设置（配置请求带名字）：发给已结束的会话时与发消息同一条路，先在后台恢复它再交给扩展改名；不写发送记录。
    @Test func 给已结束的会话改名_后台恢复后改_不写发送记录() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            PiConfig(name: "登录重试"), to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.channels.calls == [.configure(nil, nil, "登录重试", "s1.900")])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 新会话_后台开在项目目录_开场的话送入() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }

        let done = try await launched(PiLaunch(project: project.id, prompt: "看看测试为什么挂", token: "tok-1"), title: "App")

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.open(directory: directory.path, launchToken: "tok-1")])
        #expect(rig.channels.calls == [.send(PiMessage(text: "看看测试为什么挂", deliveryID: done.id.uuidString), "new-tok-1.900")])
    }

    /// 开场的话里挑了带图片的卡片：图片按原图随第一条消息送达，不把存储格式的引用当文字发出去。
    @Test func 新会话_开场的话带卡片里的图片_原图随第一条消息送入() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        let png = pngData()
        let hash = try services.store.files.store(png)
        defer { services.cancelBackgroundWork() }

        let done = try await launched(
            PiLaunch(project: project.id, prompt: "看这张设计稿\n\n![](cuepad://img/\(hash))", token: "tok-5"), title: "App")

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [
            .send(PiMessage(text: "看这张设计稿", images: [PiImage(mimeType: "image/png", data: png)], deliveryID: done.id.uuidString), "new-tok-5.900")
        ])
    }

    @Test func 新会话_没有开场的话就不发_项目没有目录时失败() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        let bare = try await services.store.createProject(name: "无目录", color: "#000000")
        defer { services.cancelBackgroundWork() }

        let quiet = try await launched(PiLaunch(project: project.id, prompt: nil, token: "tok-2"))
        #expect(quiet.status == .known(.succeeded))
        #expect(rig.host.calls == [.open(directory: directory.path, launchToken: "tok-2")])
        #expect(rig.channels.calls.isEmpty)

        let noDirectory = try await launched(PiLaunch(project: bare.id, prompt: nil, token: "tok-3"), title: "无目录")
        #expect(noDirectory.status == .known(.failed))
        #expect(noDirectory.resultDetail == SendError.noCodeDirectory("无目录").localizedDescription)
    }

    // MARK: 手机请这台 Mac 绑定文件夹（Mac 才有完整路径；绑定只有这一条写入：本机的目录绑定）

    private func bound(_ bind: PiBind) async throws -> DeliveryRequest {
        try await services.startDeliveryExecutor()
        let request = try await services.store.requestBind(bind, title: "App", on: TestApp.hostID)
        return try await awaitFinished(request.id)
    }

    @Test func 绑定_取某个会话的工作目录_写成本机的目录绑定_不写发送记录() async throws {
        let app = try folder("app")
        _ = try await indexed("s1", cwd: app)
        let project = try await services.store.createProject(name: "App", color: "#000000")
        defer { services.cancelBackgroundWork() }

        let done = try await bound(PiBind(project: project.id, folder: .besideSession("s1")))

        #expect(done.status == .known(.succeeded))
        #expect(try await services.store.directory(of: project.id) == app.path)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 绑定_取另一个项目已绑的目录_换绑覆盖旧的_没有文件夹就是解除() async throws {
        let first = try folder("first"), second = try folder("second")
        let store = services.store
        let source = try await store.createProject(name: "源", color: "#000000")
        let project = try await store.createProject(name: "App", color: "#000000")
        try await store.setDirectory(second.path, for: source.id)
        try await store.setDirectory(first.path, for: project.id)
        defer { services.cancelBackgroundWork() }

        let moved = try await bound(PiBind(project: project.id, folder: .project(source.id)))
        #expect(moved.status == .known(.succeeded))
        #expect(try await store.directory(of: project.id) == second.path)

        let unbound = try await bound(PiBind(project: project.id, folder: nil))
        #expect(unbound.status == .known(.succeeded))
        #expect(try await store.directory(of: project.id) == nil)
        #expect(try await store.directory(of: source.id) == second.path)
    }

    /// 项目记录可能还没同步到这台 Mac（手机刚新建项目就带着文件夹）：绑定按项目 id 记，记录晚到也对得上，不因此失败。
    @Test func 绑定_项目记录还没到本机也成功() async throws {
        let app = try folder("app")
        _ = try await indexed("s1", cwd: app)
        let unseen = UUID()
        defer { services.cancelBackgroundWork() }

        let done = try await bound(PiBind(project: unseen, folder: .besideSession("s1")))

        #expect(done.status == .known(.succeeded))
        #expect(try await services.store.directory(of: unseen) == app.path)
    }

    @Test func 绑定_找不到文件夹时按失败写回_原因可读_不改现有绑定() async throws {
        let existing = try folder("existing")
        _ = try await indexed("gone-folder", cwd: rig.directory.appending(path: "work/gone", directoryHint: .isDirectory))
        let project = try await services.store.createProject(name: "App", color: "#000000")
        let bare = try await services.store.createProject(name: "无目录", color: "#000000")
        try await services.store.setDirectory(existing.path, for: project.id)
        defer { services.cancelBackgroundWork() }

        let noSession = try await bound(PiBind(project: project.id, folder: .besideSession("nope")))
        #expect(noSession.status == .known(.failed) && noSession.resultDetail == SendError.piSessionNotOnThisMac.localizedDescription)
        let missing = try await bound(PiBind(project: project.id, folder: .besideSession("gone-folder")))
        #expect(missing.status == .known(.failed) && missing.resultDetail == "目录不存在：gone")
        let unbound = try await bound(PiBind(project: project.id, folder: .project(bare.id)))
        #expect(unbound.status == .known(.failed) && unbound.resultDetail == SendError.noCodeDirectory("无目录").localizedDescription)
        #expect(try await services.store.directory(of: project.id) == existing.path)
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
        let start = try await launched(PiLaunch(project: project.id, prompt: nil, token: "tok-4"), title: "App")
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

    /// 升级前开的旧协议会话没死：桥上有它，就不能当成已结束去后台唤醒（唤醒只会再起一个进程、永远"正在唤醒"）；按桥给的原因失败写回。
    @Test func 旧协议的会话还在运行_请求不唤醒_带原因失败() async throws {
        rig.channels.bridgeIDs["sess-old"] = "sess-old.100"
        rig.channels.sessions["sess-old.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "old", ref: "sess-old"), isBusy: false)
        rig.channels.sendError = PiBridgeError.incompatibleExtension
        _ = try await indexed("sess-old", cwd: try folder("old"))
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "old", ref: "sess-old"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(done.resultDetail == "这个会话正在终端里运行旧版扩展，在终端里执行 /reload 后再发")
        #expect(rig.host.calls.isEmpty)
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
