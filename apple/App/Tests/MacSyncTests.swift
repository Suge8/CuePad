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
    func session(
        _ sessionID: String, cwd: String = "/work/app", state: PiWorkState = .thinking, pid: Int32 = 100, spoke: Bool = false
    ) -> CuePi.PiSession {
        var file: URL?
        if spoke {
            file = FileManager.default.temporaryDirectory.appending(path: "mac-sync-\(UUID().uuidString).jsonl")
            FileManager.default.createFile(atPath: file!.path, contents: Data())
        }
        return CuePi.PiSession(
            id: "\(sessionID).\(pid)", sessionID: sessionID, agent: .pi, sessionFile: file, pid: pid, cwd: URL(filePath: cwd, directoryHint: .isDirectory),
            terminal: PiTerminal(), state: state, stateSince: .now)
    }

    func changes(_ items: [PiSessionChange]) -> AsyncStream<PiSessionChange> {
        AsyncStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: 退出

    /// 退出可能发生在主线程被占住时：在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等收尾的回复，
    /// 主线程上排队的任务轮不到。收尾的等待部分若需要主线程，退出就永远等不到。
    @Test
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
    nonisolated static func blockCurrentThread(until signal: DispatchSemaphore, seconds: Double) -> Bool {
        signal.wait(timeout: .now() + seconds) == .success
    }

    @Test
    func 退出收尾有上限_组件卡住时到点放行并指出是哪个() async throws {
        services.startSync()
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }
        rig.sync.stopHangs.withLock { $0 = true }

        let late = await services.beginShutdown(within: .milliseconds(200))()

        #expect(late == "同步")
        #expect(rig.sync.stopped == 1)
    }

    /// 退出时这台 Mac 当场离线：排在前面的组件卡住、耗尽了收尾的上限，离线这一条也已写下并上传。
    @Test
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
    @Test
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

    /// 更新版本的扩展报来本版本不认识的取值（思考强度、子代理阶段）：原样写进同步记录，认得它的设备照常读。
    @Test func 桥报来不认识的取值原样写进同步记录() async throws {
        var live = session("s1")
        live.thinking = .unknown("ultra")
        live.subagents = [PiSubagentState(name: "docs", role: "写手", phase: .unknown("napping"))]
        try await services.consumePiChanges(changes([.appeared(live)]))

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.thinking == .unknown("ultra") && stored.subagents.map(\.phase) == [.unknown("napping")])
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
        let row = try #require(PiSessionState.live(live, hostID: TestApp.hostID, projectID: nil, recap: PiRecap(lastReply: "做完了")))
        #expect(!services.settings.isUnread(row))
        #expect(try #require(services.pi.session(id: changed.id)).stateSince > past)
    }

    /// 本机标识写在每条同步记录上：派生方式一变，这台 Mac 写过的记录就都不认了；也不带出硬件 UUID 原值。
    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        #expect(HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001") == "mac-8644cc63caf7fc7a")
    }
}
#endif
