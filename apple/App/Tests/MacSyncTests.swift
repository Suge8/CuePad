#if os(macOS)
import struct CueStore.PiSession
import CueStore
import CueSync
import Foundation
import Testing
import AppKit
@testable import CuePad
@testable import CuePi

/// Mac 端的同步职责：唤醒时同步；把 Pi 会话状态写成同步记录；执行手机发来的投送请求。
struct MacSyncTests {
    let rig = TestApp()
    var services: AppServices { rig.services }

    /// `spoke`：留下了会话文件（说过话）；没有文件的会话结束时不进历史。
    private func session(
        _ sessionID: String, cwd: String = "/work/app", state: PiWorkState = .thinking, pid: Int32 = 100, spoke: Bool = false
    ) -> CuePi.PiSession {
        var file: URL?
        if spoke {
            file = FileManager.default.temporaryDirectory.appending(path: "mac-sync-\(UUID().uuidString).jsonl")
            FileManager.default.createFile(atPath: file!.path, contents: Data())
        }
        return CuePi.PiSession(
            id: "\(sessionID).\(pid)", sessionID: sessionID, sessionFile: file, pid: pid, cwd: URL(filePath: cwd, directoryHint: .isDirectory),
            terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version, state: state, stateSince: .now)
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
        try await services.executor.start()
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }

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
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }
        rig.sync.stopHangs.withLock { $0 = true }

        let late = await services.stop(within: .milliseconds(200))

        #expect(late == "同步引擎")
        #expect(rig.sync.stopped == 1)
    }

    @Test func 退出时停止同步引擎与远程投送执行器() async throws {
        services.startSync()
        try await services.executor.start()
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }

        await services.stop()

        #expect(rig.sync.stopped == 1)
        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .mac, name: "CuePad"), on: TestApp.hostID)
        // 停止后不再有观察者领取：给执行器足够的时间再确认仍未处理
        await quietPeriod(.milliseconds(300))
        #expect(try await services.store.deliveryRequest(request.id)?.status == .known(.pending))
    }

    // MARK: 唤醒

    @Test func 系统唤醒时立即同步() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await eventually("rig.sync.syncNows == 1") { rig.sync.syncNows == 1 }
        #expect(rig.sync.syncNows == 1)
    }

    // MARK: Pi 状态记录

    /// 桥上会话的每个字段原样写进同步记录（手机据此画状态、计时、子代理、用量条、命令面板、模型选择与弹窗）；
    /// 它们怎么从线上消息得来见 CuePi 的桥测试。本版本不认识的新取值原样留着。
    @Test func 会话的状态与各字段原样写进同步记录() async throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let sonnet = PiModelOption(key: PiModelKey(provider: "anthropic", id: "sonnet"), name: "Sonnet", thinkingLevels: [.off, .low])
        let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.off, .high])
        let subagents = [
            PiSubagentState(name: "ui", role: "工程师", phase: .known(.running), action: "运行 bun test", startedAt: started, model: "anthropic/claude-opus-5-5"),
            PiSubagentState(name: "docs", role: "写手", phase: .unknown("napping")),
        ]
        let commands = [
            PiSlashCommand(name: "compact", summary: "压缩上下文", source: .known(.builtin), hint: "[说明]"),
            PiSlashCommand(name: "x", summary: nil, source: .unknown("plugin")),
        ]
        let question = PiQuestion(promptID: "p-1", kind: .select, text: "选哪个？", options: ["A", "B"])
        var live = session("s1", state: .waitingForUser)
        live.detail = "read · README.md"
        live.stateSince = started
        live.busySince = started
        live.subagents = subagents
        live.model = opus
        live.thinking = .unknown("ultra")
        live.availableModels = [sonnet, opus]
        live.context = PiContextUsage(tokens: 42_000, window: 200_000)
        live.commands = commands
        live.question = question
        live.launchToken = "tok-1"
        try await services.consumePiChanges(changes([.appeared(live)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.state == .known(.waitingForUser) && stored.detail == "read · README.md")
        #expect(stored.sessionID == "s1" && stored.hostID == TestApp.hostID)
        #expect(stored.stateSince == started && stored.busySince == started)
        #expect(stored.subagents == subagents)
        #expect(stored.model == opus && stored.thinking == .unknown("ultra") && stored.models.map(\.key.id) == ["sonnet", "opus"])
        #expect(stored.context == PiContextUsage(tokens: 42_000, window: 200_000))
        #expect(stored.commands == commands)
        #expect(stored.question == question)
        #expect(try await services.store.piSessionPage(PiSessionQuery(launchToken: "tok-1")).items.map(\.state.sessionID) == ["s1"])
    }

    @Test func 会话按工作目录归入项目_结束后记录保留为已结束() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory("/work", for: project.id)

        try await services.consumePiChanges(changes([.appeared(session("s1", cwd: "/work/app"))]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.projectID == project.id)
        #expect(stored.title == "app")

        try await services.consumePiChanges(changes([.ended(session("s1", spoke: true), reason: .disconnected)]))
        #expect(try await services.store.allPiSessionStates().map(\.state) == [.known(.ended)])
    }

    /// 会话在压缩上下文时关掉，扩展留着还没交给 Pi 的话在告别里报出：这台 Mac 已经写成"送到了"的那条改记为没送到，
    /// 走"没能送达 + 重发"那条路（列表行与会话页的没送到计数里有它）；别的会话、别的请求不动。
    @Test func 告别里报没送到的话_记为没能送达() async throws {
        let store = services.store
        try await services.consumePiChanges(changes([.appeared(session("s1"))]))
        let target = SendTarget(kind: .piSession, name: "s1", ref: "s1")
        let lost = try await store.requestDelivery("压缩时说的话", to: target, on: TestApp.hostID, mode: .send)
        let kept = try await store.requestDelivery("早先说的话", to: target, on: TestApp.hostID, mode: .send)
        let executor = DeliveryExecutor(store: store, hostID: TestApp.hostID, onIssue: { _ in }) { _ in .succeeded }
        try await executor.start()
        for id in [lost.id, kept.id] {
            _ = try await eventually(store, { try $0.deliveryRequest(id)?.isOpen }) { $0 == false }
        }
        await executor.stop()

        try await services.consumePiChanges(changes([.ended(session("s1", spoke: true), reason: .closed(reason: "quit", undelivered: [lost.id.uuidString]))]))

        let failed = try #require(try await store.deliveryRequest(lost.id))
        #expect(failed.status == .known(.failed) && failed.resultDetail == "会话在压缩上下文时关掉了，这句没送进去")
        #expect(try await store.deliveryRequest(kept.id)?.status == .known(.succeeded))
        #expect(try await store.piSessionPage(PiSessionQuery()).items.first?.undelivered == 1)
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
                for try await request in store.observe({ try $0.deliveryRequest(id) }) {
                    if let request, request.status == .known(.succeeded) || request.status == .known(.failed) { return request }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TimedOut(what: "投送请求 \(id) 没有在 60 秒内出结果")
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
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "做这件事", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .steer)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        // 带上请求 id：扩展写进会话文件里那条消息，对话据此把请求气泡换成它
        #expect(ext.messages == [PiMessage(text: "做这件事", whenBusy: .steer, deliveryID: request.id.uuidString)])
        #expect(done.handledBy == TestApp.hostID)
    }

    /// 斜杠命令走桥的命令通道（由 Pi 展开执行，不是当文字发出）；忙时按"等它做完再说"排队，和发出去的话一样记发送记录。
    @Test func 手机的斜杠命令请求交给桥按命令执行() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "/greet world", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        let sent = try #require(ext.commands.last?.json)
        #expect(ext.received == ["command"] && sent["text"] as? String == "/greet world" && sent["deliverAs"] as? String == "followUp")
        #expect(try await services.store.sendRecords().isEmpty)  // 发送记录只记内容的投送，命令不记
    }

    /// 发给 Agent 时命令带着卡片（卡片文字是参数）：卡片关联到会话、任务进行中，照样不写发送记录。
    @Test func 带卡片的斜杠命令只关联卡片_不写发送记录() async throws {
        _ = try await rig.host.connect("sess-1", cwd: "/work/app")
        let task = try await services.store.createTask("改登录", in: nil)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "/greet\n\n改登录", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command, card: task.id)
        _ = try await awaitFinished(request.id)

        let linked = try #require(try await services.store.card(task.id))
        #expect(linked.piSessionID == "sess-1" && linked.status == .inProgress)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 斜杠命令里带图片按失败写回() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        // 图片文件在本机（没到的图片执行器会等它同步过来，那是另一条路径）
        let hash = try services.store.files.store(pngData(shade: 0.3))
        let request = try await services.store.requestDelivery(
            "/greet\n\n![](cuepad://img/\(hash))", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(ext.commands.isEmpty)
    }

    @Test func 手机的作答请求交给扩展作答_不写发送记录() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestAnswer(
            PiAnswer(promptID: "p-1", value: .option("覆盖")), to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"),
            on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        let sent = try #require(ext.commands.last?.json)
        #expect(ext.received == ["answer"] && sent["promptId"] as? String == "p-1" && sent["value"] as? String == "覆盖")
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 手机的配置请求交给桥改模型与思考强度_不写发送记录() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            PiConfig(model: PiModelKey(provider: "anthropic", id: "opus"), thinking: .high),
            to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        let sent = try #require(ext.commands.last?.json)
        #expect(ext.received == ["config"] && sent["model"] as? [String: String] == ["provider": "anthropic", "id": "opus"] && sent["thinking"] as? String == "high")
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 手机的结束请求让会话收尾_不写发送记录() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestEnd(of: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.end(ext.id)])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 已经结束的会话（不在这台 Mac 的桥上）没有可结束的会话、也没有这一轮可停：目标达成，按成功写回，不恢复它、不碰桥。
    @Test(arguments: [DeliveryMode.end, .stop])
    func 结束或停止已经结束的会话直接成功_不恢复(mode: DeliveryMode) async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let target = SendTarget(kind: .piSession, name: "app", ref: "old")
        let request = mode == .end
            ? try await services.store.requestEnd(of: target, on: TestApp.hostID)
            : try await services.store.requestStop(of: target, on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls.isEmpty)
    }

    @Test func 手机的停止请求让桥中止这一轮_不写发送记录() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestStop(of: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(ext.received == ["abort"])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 手机上停止、结束、改配置：请求都发给会话所在的那台 Mac，写出后立即上传（与发送、作答同一条通路）。
    @Test(.timeLimit(.minutes(1)))
    func 请求停止_结束_改配置写给会话所在的Mac并立即上传() async throws {
        try await PiStateRecorder(store: services.store, hostID: "mac-other").update(sessionID: "far", state: .thinking, title: "远处")
        let session = try #require(try await services.store.allPiSessionStates().first)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        let stop = try await services.stop(session)
        #expect(stop.hostID == "mac-other" && stop.mode == .known(.stop) && stop.target.ref == "far")
        #expect(await uploads.next() == stop.id.uuidString.lowercased())

        let end = try await services.end(session)
        #expect(end.hostID == "mac-other" && end.mode == .known(.end) && end.target.ref == "far")
        #expect(await uploads.next() == end.id.uuidString.lowercased())

        let config = try await services.configure(PiConfig(thinking: .low), for: session)
        #expect(config.hostID == "mac-other" && config.config == PiConfig(thinking: .low) && config.target.ref == "far")
        #expect(await uploads.next() == config.id.uuidString.lowercased())
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
        #expect(services.pollingCadence == SyncPoller.Cadence(.every(.seconds(2))))
    }

    @Test func 连接测试请求立即完成_不碰Pi_不写发送记录() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded) && done.mode == .known(.ping))
        #expect(try await services.store.sendRecords().isEmpty)
    }

    /// 写回结果后立即只上传这一条，不等引擎调度：手机才能尽早拉到结果。
    @Test(.timeLimit(.minutes(1)))
    func 执行器写回结果后立即上传这一条() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        #expect(await uploads.next() == request.id.uuidString.lowercased())
        #expect(try await services.store.deliveryRequest(request.id)?.isOpen == false)
    }

    // MARK: 后台恢复、开新会话

    private func launched(_ launch: PiLaunch, title: String = "app", card: UUID? = nil) async throws -> DeliveryRequest {
        try await services.executor.start()
        let request = try await services.store.requestLaunch(launch, title: title, on: TestApp.hostID, card: card)
        return try await awaitFinished(request.id)
    }

    /// 测试目录里的一个真实文件夹（执行器启动前检查目录存在）。
    private func folder(_ name: String) throws -> URL {
        let url = rig.directory.appending(path: "work/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func indexed(_ id: String, cwd: URL) async throws -> PiSession {
        let session = PiSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd.path, title: "修好登录", lastActivityAt: .now)
        try await services.store.upsertPiSession(session, host: TestApp.hostID)
        return session
    }

    @Test func 给已结束的会话发消息_后台恢复后送达() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "接着做", to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.host.extensions["s1"]?.messages == [PiMessage(text: "接着做", deliveryID: request.id.uuidString)])
    }

    /// 改名是会话设置（配置请求带名字）：发给已结束的会话时与发消息同一条路，先在后台恢复它再交给扩展改名；不写发送记录。
    @Test func 给已结束的会话改名_后台恢复后改_不写发送记录() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            PiConfig(name: "登录重试"), to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.host.extensions["s1"]?.commands.last?.json["name"] as? String == "登录重试")
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
        #expect(rig.host.extensions["new-tok-1"]?.messages == [PiMessage(text: "看看测试为什么挂", deliveryID: done.id.uuidString)])
    }

    /// 从步骤开的新会话叫步骤名：先起名，再送开场的话（会话名不会先成了第一句话）。
    @Test func 新会话_从步骤开_以步骤命名() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let task = try await services.store.createTask("上线", in: project.id)
        let step = try await services.store.createTask("备份数据库", under: task.id)
        let prompt = try await services.store.createCard(body: "先把库备份一份", under: step.id)

        let done = try await launched(PiLaunch(project: project.id, prompt: prompt.body, token: "tok-6"), card: prompt.id)

        #expect(done.status == .known(.succeeded))
        let ext = try #require(rig.host.extensions["new-tok-6"])
        #expect(ext.received == ["config", "send"])
        #expect(ext.commands.first?.json["name"] as? String == "备份数据库")
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
        #expect(rig.host.extensions["new-tok-5"]?.messages == [
            PiMessage(text: "看这张设计稿", images: [PiImage(mimeType: "image/png", data: png)], deliveryID: done.id.uuidString)
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
        #expect(rig.host.extensions["new-tok-2"]?.commands.isEmpty == true)

        let noDirectory = try await launched(PiLaunch(project: bare.id, prompt: nil, token: "tok-3"), title: "无目录")
        #expect(noDirectory.status == .known(.failed))
        #expect(noDirectory.resultDetail == SendError.noCodeDirectory("无目录").localizedDescription)
    }

    // MARK: 手机请这台 Mac 绑定文件夹（Mac 才有完整路径；绑定只有这一条写入：本机的目录绑定）

    private func bound(_ bind: PiBind) async throws -> DeliveryRequest {
        try await services.executor.start()
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
        try await services.executor.start()
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
        mine.state = .tool
        try await services.consumePiChanges(changes([
            .appeared(hosted), .appeared(mine), .stateChanged(hosted, from: .thinking), .ended(hosted, reason: .closed(reason: "quit")),
        ]))

        let records = try await services.store.allPiSessionStates()
        #expect(records.count == 1)
        #expect(records.first?.hosted == false && records.first?.state == .known(.tool))
    }

    /// 项目在哪台 Mac 上绑定了目录（只带目录末段名）同步给手机：Mac 绑定、解绑后随之写、删。
    @Test(.timeLimit(.minutes(1)))
    func 目录绑定随绑定与解绑同步() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.startDirectoryBindings()
        defer { services.cancelBackgroundWork() }

        try await services.store.setDirectory("/Users/someone/work/app", for: project.id)
        var bound: [DirectoryBinding] = []
        for try await bindings in services.store.observe({ try $0.directoryBindings() }) where !bindings.isEmpty {
            bound = bindings
            break
        }
        #expect(bound.map(\.projectID) == [project.id] && bound.map(\.hostID) == [TestApp.hostID] && bound.map(\.folder) == ["app"])

        try await services.store.setDirectory(nil, for: project.id)
        for try await bindings in services.store.observe({ try $0.directoryBindings() }) where bindings.isEmpty { break }
    }

    /// 升级前开的旧协议会话没死：桥上有它，就不能当成已结束去后台唤醒（唤醒只会再起一个进程、永远"正在唤醒"）；按桥给的原因失败写回。
    @Test func 旧协议的会话还在运行_请求不唤醒_带原因失败() async throws {
        try await rig.host.connect("sess-old", cwd: "/work/old", protocolVersion: 3)
        _ = try await indexed("sess-old", cwd: try folder("old"))
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "old", ref: "sess-old"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(done.resultDetail == "这个会话正在终端里运行旧版扩展，在终端里执行 /reload 后再发")
        #expect(rig.host.calls.isEmpty)
    }

    @Test func 目标会话已结束时请求失败并说明原因() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "gone", ref: "sess-gone"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(done.resultDetail?.contains("会话") == true)
        #expect(rig.host.calls.isEmpty)
    }

    /// 投送到应用已经下线：旧版本写来的发到应用、复制到剪贴板的请求按失败写回，不碰任何应用与剪贴板。
    @Test func 旧版本写来的发到应用请求按失败写回() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .unknown("app"), name: "Ghostty", ref: "com.mitchellh.ghostty"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        let first = HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001")
        #expect(first == HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001"))
        #expect(first != HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000002"))
        #expect(first.hasPrefix("mac-") && !first.contains("A1B2C3D4"))
    }
}
#endif
