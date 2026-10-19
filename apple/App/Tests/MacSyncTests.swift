#if os(macOS)
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
            id: "\(sessionID).\(pid)", sessionID: sessionID, agent: .pi, sessionFile: file, pid: pid, cwd: URL(filePath: cwd, directoryHint: .isDirectory),
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
        #expect(Self.blockCurrentThread(until: done, seconds: 30), "主线程被占住时收尾等不到")
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

        let late = await services.beginShutdown(within: .milliseconds(200))()

        #expect(late == "同步")
        #expect(rig.sync.stopped == 1)
    }

    /// 退出时这台 Mac 当场离线：排在前面的组件卡住、耗尽了收尾的上限，离线这一条也已写下并上传。
    @Test(.timeLimit(.minutes(1)))
    func 退出时这台Mac离线_前面的组件卡住也不漏() async throws {
        // Cue 的大脑起不来、也取消不了，直到断言后放行：停 Cue 这一步卡住（等的是不随取消结束的任务）
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let rig = TestApp(cue: CueDependencies(
            launch: { _, _ in await Task { for await _ in gate {} }.value; return nil },
            helper: URL(filePath: "/usr/bin/true"), notifier: RecordingCueNotifier()))
        let services: AppServices = rig.services, host = TestApp.hostID
        let record = MacPresence.recordID(host: host).uuidString.lowercased()
        var uploads = rig.sync.uploads.stream.filter { $0 == record }.makeAsyncIterator()
        try await services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
        }
        services.start()
        #expect(await uploads.next() == record)
        try await eventually("Cue 在这台值班") { services.cue.onDuty }

        #expect(await services.beginShutdown(within: .milliseconds(300))() == "Cue")

        #expect(await uploads.next() == record)
        #expect(try await !services.store.macOnline(host))
    }

    @Test func 退出时停止同步与远程投送执行器() async throws {
        services.startSync()
        try await services.executor.start()
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }

        _ = await services.beginShutdown()()

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
        // 启动后的第一次拉也走立即同步
        try await eventually("启动后拉一次") { rig.sync.started == 1 && rig.sync.syncNows == 1 }

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await eventually("rig.sync.syncNows == 2") { rig.sync.syncNows == 2 }
        #expect(rig.sync.syncNows == 2)
    }

    /// 这台 Mac 的在线记录（别的设备判断它在不在、Cue 在不在值班只看它）：启动即在线，醒着每 5 分钟续期，每次都立即上传；
    /// 将睡眠的通知返回时离线已经写下并传出；睡着时到点不续；醒来立即又在线。
    @Test(.timeLimit(.minutes(1)))
    func 在线记录_启动即在线_醒着定期续期_将睡眠当场离线_醒来又在线() async throws {
        let clock = ManualTiming()
        let rig = TestApp(timing: clock.timing)
        let services: AppServices = rig.services, store = services.store, host = TestApp.hostID
        let record = MacPresence.recordID(host: host).uuidString.lowercased()
        var uploads = rig.sync.uploads.stream.filter { $0 == record }.makeAsyncIterator()
        services.start()
        defer { services.cancelBackgroundWork() }

        #expect(await uploads.next() == record)
        #expect(try await store.macOnline(host))

        await clock.waitForSleeper()
        clock.advance(MacPresence.renewal)
        #expect(await uploads.next() == record)  // 续期
        #expect(try await store.macOnline(host))

        rig.wakeCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(try await !store.macOnline(host))
        #expect(await uploads.next() == record)
        await clock.waitForSleeper()
        clock.advance(MacPresence.renewal)
        await clock.waitForSleeper()
        #expect(try await !store.macOnline(host))

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await uploads.next() == record)
        #expect(try await store.macOnline(host))
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
        #expect(stored.model == opus && stored.thinking == .unknown("ultra"))
        #expect(stored.context == PiContextUsage(tokens: 42_000, window: 200_000))
        let catalogID = try #require(stored.catalogID)
        let catalog = try #require(try await services.store.agentCatalog(catalogID))
        #expect(catalog.models.map(\.key.id) == ["sonnet", "opus"] && catalog.commands == commands)
        #expect(stored.question == question)
        #expect(try await services.store.piSessionPage(PiSessionQuery(launchToken: "tok-1")).items.map(\.state.sessionID) == ["s1"])
    }

    @Test func 会话按工作目录归入项目_结束后记录保留为已结束() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory("/work", for: project.id)

        try await services.consumePiChanges(changes([.appeared(session("s1", cwd: "/work/app", state: .settled))]))
        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.projectID == project.id)
        #expect(stored.title == "app")

        try await services.consumePiChanges(changes([.ended(session("s1", spoke: true), reason: .disconnected)]))
        #expect(try await services.store.allPiSessionStates().map(\.state) == [.known(.ended)])
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
        try await mine.update(sessionID: "old", state: .settled, process: PiProcess(pid: 1, startedAt: 1))  // 记下的进程已不在
        try await other.update(sessionID: "theirs", state: .thinking)

        try await services.resetPiState()

        let states = Dictionary(uniqueKeysWithValues: try await services.store.allPiSessionStates().map { ($0.sessionID, $0.state) })
        #expect(states == ["old": .known(.ended), "theirs": .known(.thinking)])
    }

    /// App 重开：接回的会话"多久前"与"有新回复"仍从原来的起点算（看过的不又亮"有新回复"，排序不乱）；状态种类变了才从接回时算。
    /// 各家接入上桥时都报"现在"（这里的假扩展也是），起点只在桥上定一次，界面与同步记录读的是同一个。
    @Test func 重开后接回的会话沿用原来的起点_看过的不又成有新回复() async throws {
        let past = Date.now.addingTimeInterval(-3600)
        let before = PiStateRecorder(store: services.store, hostID: TestApp.hostID)
        try await before.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: past, busySince: nil))
        try await before.update(sessionID: "s2", state: .thinking, times: PiTimes(stateSince: past, busySince: past))
        let seen = try #require(try await services.store.allPiSessionStates().first { $0.sessionID == "s1" })
        services.settings.markSeen(seen, at: past.addingTimeInterval(1))

        try await services.resetPiState()
        let kept = try await rig.host.connect("s1", cwd: "/work/s1")
        let changed = try await rig.host.connect("s2", cwd: "/work/s2")

        let live = try #require(services.pi.session(id: kept.id))
        #expect(live.stateSince == seen.stateSince)
        let row = PiSessionState.live(live, hostID: TestApp.hostID, projectID: nil, recap: PiRecap(lastReply: "做完了"))
        #expect(!services.settings.isUnread(row))
        #expect(try #require(services.pi.session(id: changed.id)).stateSince > past)
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
            "做这件事", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        // 带上请求 id：扩展写进会话文件里那条消息，对话据此把请求气泡换成它
        #expect(ext.messages == [PiMessage(text: "做这件事", deliveryID: request.id.uuidString)])
        #expect(done.handledBy == TestApp.hostID)
    }

    /// 斜杠命令走桥的命令通道（由 Pi 展开执行，不是当文字发出），不记发送记录。
    @Test func 手机的斜杠命令请求交给桥按命令执行() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "/greet world", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID, mode: .command)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        let sent = try #require(ext.commands.last?.json)
        #expect(ext.received == ["command"] && sent["text"] as? String == "/greet world")
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)  // 发送记录只记内容的投送，命令不记
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    @Test func 手机的结束请求让会话收尾_不写发送记录() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app", busy: true)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestEnd(of: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(ext.received == ["end"] && rig.host.calls.isEmpty)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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
        services.startSpeechClock()
        var waiting = services.pollingCondition().makeAsyncIterator()
        #expect(await waiting.next() == .some(nil))

        _ = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        while let next = await waiting.next(), next == nil {}
        #expect(services.pollingCadence == SyncPoller.Cadence(.every(.seconds(2))))
    }

    /// Cue 在这台值班也是在等：你在手机上对它说的话、"等你"的回答只经主动拉取到达，会话都关着、没有在路上的请求时也拉。
    @Test(.timeLimit(.minutes(1)))
    func 主动拉取的条件_Cue在这台值班时也拉() async throws {
        #expect(services.pollingCadence == nil)
        try await services.store.updateCueProfile { [hostID = TestApp.hostID] in
            $0.hostID = hostID
            $0.enabledAt = .now
        }
        services.start()
        defer { services.cancelBackgroundWork() }
        try await eventually("Cue 在这台值班") { services.cue.onDuty }
        #expect(services.pi.slots.isEmpty && !services.hasOpenDeliveries)
        #expect(services.pollingCadence == SyncPoller.Cadence(.every(.seconds(2))))
    }

    @Test func 连接测试请求立即完成_不碰Pi_不写发送记录() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded) && done.mode == .known(.ping))
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 领取与写回结果后各立即只上传这一条，不等引擎调度：手机才能尽早知道 Mac 接手了、拉到结果。
    /// 领取那次在后台任务里传，两次的先后不定：两次都传过才说明结果已写回并传出。
    @Test(.timeLimit(.minutes(1)))
    func 执行器领取与写回结果后各立即上传这一条() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestPing(on: TestApp.hostID)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()
        let name = request.id.uuidString.lowercased()

        #expect(await uploads.next() == name)
        #expect(await uploads.next() == name)
        #expect(try await services.store.deliveryRequest(request.id)?.isOpen == false)
    }

    // MARK: 订阅额度（Mac 唯一写入，手机只读）

    /// 桥报来的额度一直写进库（`start()` 里同一条路），直到测试结束。
    private func recordingQuotas() {
        let changes = services.pi.changes()
        services.follow { try? await self.services.consumePiChanges(changes) }
    }

    private static let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let claude: [[String: Any]] = [
        ["seconds": 18_000, "used": 0.42, "resetsAt": resetsAt.timeIntervalSince1970, "binding": true],
        ["seconds": 604_800, "used": 0.1, "resetsAt": resetsAt.timeIntervalSince1970 + 86_400],
    ]

    private func quota(_ provider: String) async throws -> AccountQuota {
        try await eventually(services.store, { try $0.accountQuotas() }) { $0.contains { $0.provider == provider } }
            .first { $0.provider == provider }!
    }

    @Test(.timeLimit(.minutes(1)))
    func 回复里带回的额度写进这个账号的记录() async throws {
        recordingQuotas()
        defer { services.cancelBackgroundWork() }
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")

        ext.sendQuota(provider: "anthropic", windows: Self.claude, complete: false)

        let stored = try await quota("anthropic")
        #expect(stored.hostID == TestApp.hostID)
        #expect(stored.windows == [
            QuotaWindow(seconds: 18_000, used: 0.42, resetsAt: Self.resetsAt, isBinding: true),
            QuotaWindow(seconds: 604_800, used: 0.1, resetsAt: Self.resetsAt.addingTimeInterval(86_400)),
        ])
    }

    /// 手机打开额度视图、数据陈旧时写的刷新请求：Mac 经在线会话里的扩展查一次，查到的写进账号记录，请求按成功写回。
    @Test(.timeLimit(.minutes(1)))
    func 手机的额度刷新请求经在线会话查到_写回额度与成功() async throws {
        recordingQuotas()
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")
        let resetsAt = Self.resetsAt.timeIntervalSince1970
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "quota" {
                ext?.sendQuota(provider: "openai-codex", windows: [["seconds": 604_800, "used": 0.91, "resetsAt": resetsAt]], complete: true)
            }
            return ["ok": true]
        }

        let request = try await services.store.requestQuotaRefresh(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(ext.received == ["quota"])
        #expect(try await quota("openai-codex").windows == [QuotaWindow(seconds: 604_800, used: 0.91, resetsAt: Self.resetsAt)])
    }

    @Test func 手机的额度刷新请求_这台Mac没有在线会话时按失败写回原因() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestQuotaRefresh(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.failure == "这台 Mac 上没有在线的 Agent 会话，查不了额度")
        #expect(try await services.store.accountQuotas().isEmpty)
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

    private func indexed(_ id: String, cwd: URL) async throws -> IndexedSession {
        let session = IndexedSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd.path, title: "修好登录", lastActivityAt: .now)
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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

    /// 从步骤开的新会话叫步骤名：会话名与模型、思考强度一样是 Pi 的启动参数，开出来就叫它，再送开场的话（会话名不会先成了第一句话）。
    @Test func 新会话_从步骤开_以步骤命名() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let task = try await services.store.createTask("上线", in: project.id)
        let step = try await services.store.createTask("备份数据库\n先把库备份一份", under: task.id)

        let done = try await launched(PiLaunch(project: project.id, prompt: step.body, token: "tok-6"), card: step.id)

        #expect(done.status == .known(.succeeded))
        let ext = try #require(rig.host.extensions["new-tok-6"])
        #expect(ext.received == ["send"])
        guard case .open(_, _, let name, _, _) = try #require(rig.host.calls.first) else {
            Issue.record("没有开新会话")
            return
        }
        #expect(name == "备份数据库")
    }

    /// Cue 开的新会话：开场白同所有送进会话的话一样记发送记录（带请求 id 与来源），请求清理之后会话页里它仍标着 Cue。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func Cue开的新会话_请求清理之后开场白仍标着Cue() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let store = services.store

        try await services.executor.start()
        let request = try await store.requestLaunch(
            PiLaunch(project: project.id, prompt: "看看测试为什么挂", token: "tok-cue"), title: "App", on: TestApp.hostID, cue: true)
        let done = try await awaitFinished(request.id)
        #expect(done.status == .known(.succeeded))
        let ext = try #require(rig.host.extensions["new-tok-cue"])
        try await store.deleteDelivery(request.id)
        let said = PiChatMessage(sessionID: ext.sessionID, entryID: "u0", seq: 0, role: .user, text: "看看测试为什么挂", at: .now, deliveryID: request.id)
        try await store.writePiTranscript(PiTranscript(sessionID: ext.sessionID, messages: [said], recap: PiRecap(lastPrompt: said.text)))

        let digest = try await SessionDigest.read(PiSessionState.recordID(sessionID: ext.sessionID), sessionID: ext.sessionID, from: store)
        let derived = ChatDerived()
        derived.refresh(digest)

        #expect(digest.deliveries.isEmpty)
        let entry = try #require(derived.items.first)
        #expect(entry.fromCue)
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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
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
    /// 扩展升级后旧版会话在终端里 /reload：旧协议的连接告别、新扩展接回同一个会话。说过话的会话这时不是"没说话就退出"，
    /// 记录与它的摘要留着，接回后不变成"新会话"。
    @Test(.timeLimit(.minutes(1)))
    func 旧协议会话重载接回_摘要还在() async throws {
        let changes = rig.pi.changes()
        try rig.pi.start()
        let services: AppServices = services
        let consuming = Task { try await services.consumePiChanges(changes) }
        defer { consuming.cancel() }
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-sync-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let store = services.store

        let old = try await rig.host.connect("s1", cwd: "/work/app", protocolVersion: 3, sessionFile: file.path)
        _ = try await eventually(store, { try $0.allPiSessionStates().first }, until: { $0?.state == .known(.incompatible) })
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s1", messages: [PiChatMessage(sessionID: "s1", entryID: "u1", seq: 1, role: .user, text: "修登录", at: .now)],
            recap: PiRecap(lastPrompt: "修登录", lastReply: "改好了")))

        old.close(bye: "reload")
        try await rig.host.connect("s1", cwd: "/work/app", sessionFile: file.path)

        let back = try await eventually(store, { try $0.allPiSessionStates().first }, until: { $0?.state == .known(.settled) })
        #expect(back?.recap == PiRecap(lastPrompt: "修登录", lastReply: "改好了"))
    }

    /// 后台托管的会话进程没了（App 退出、闲置退出）记录仍歇着、发话会唤醒它：它报过的斜杠命令留着，
    /// 回复框里打完整的 "/default" 照样是命令（后台唤醒后执行），不当普通的话发给模型。会话做完的也一样。
    @Test(arguments: [true, false])
    func 进程没了的会话仍认它报过的斜杠命令(hosted: Bool) async throws {
        var live = session("s1", state: .settled, spoke: true)
        live.hosted = hosted
        live.commands = [PiSlashCommand(name: "default", summary: "回默认模式", source: .known(.builtin))]
        try await services.consumePiChanges(changes([.appeared(live), .ended(live, reason: .disconnected)]))
        if !hosted { try await PiStateRecorder(store: services.store, hostID: TestApp.hostID).end(sessionID: "s1") }

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.state == .known(hosted ? .settled : .ended))
        let catalogID = try #require(stored.catalogID)
        let catalog = try await services.store.agentCatalog(catalogID)
        #expect(catalog?.models.isEmpty ?? true)  // 可选模型不留
        #expect(PiSlash.line(of: ComposerDraft(text: "/default"), in: stored.usableCommands(in: catalog)) == "/default")
    }

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
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        let first = HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001")
        #expect(first == HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001"))
        #expect(first != HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000002"))
        #expect(first.hasPrefix("mac-") && !first.contains("A1B2C3D4"))
    }
}
#endif
