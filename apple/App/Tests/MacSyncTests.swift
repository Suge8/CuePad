#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
import AppKit
import Synchronization
@testable import CuePad
@testable import CuePi

@Suite(.releasesLibraries)
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
    @Test(arguments: [true, false])
    func 主线程被占住时退出收尾仍在上限内完成(uploadAccepted: Bool) async throws {
        rig.sync.sendsSucceed.withLock { $0 = uploadAccepted }
        services.startSync()
        try await services.executor.start()
        try await eventually("rig.sync.started == 1") { rig.sync.started == 1 }

        let finish = services.beginShutdown(within: .seconds(2))
        let done = DispatchSemaphore(value: 0), outcome = Mutex<String?>(nil)
        Task.detached {
            let failure = await finish()
            outcome.withLock { $0 = failure }
            done.signal()
        }
        #expect(holdThread(until: done), "主线程被占住时收尾等不到")
        let failure = outcome.withLock { $0 }
        #expect(uploadAccepted ? failure == nil : failure?.contains("尚未确认云端已接受") == true)
        #expect(rig.sync.stopped == 1)
    }

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
        let uploads = Watch(rig.sync.uploads.stream) { $0 == record }
        try await services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
        }
        services.start()
        #expect(try await uploads.next("在线记录上传") == record)
        try await eventually("Cue 在这台值班") { services.cue.onDuty }

        #expect(await services.beginShutdown(within: .milliseconds(300))() == "Cue")

        #expect(try await uploads.next("在线记录上传") == record)
        #expect(try await !services.store.macOnline(host))
    }

    // MARK: 唤醒

    @Test func 系统唤醒时立即同步() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("启动后拉一次") { rig.sync.started == 1 && rig.sync.syncNows == 1 }

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await eventually("rig.sync.syncNows == 2") { rig.sync.syncNows == 2 }
        #expect(rig.sync.syncNows == 2)
    }

    @Test
    func 在线记录_启动即在线_醒着定期续期_将睡眠当场离线_醒来又在线() async throws {
        let clock = ManualTiming()
        let rig = TestApp(timing: clock.timing)
        let services: AppServices = rig.services, store = services.store, host = TestApp.hostID
        let record = MacPresence.recordID(host: host).uuidString.lowercased()
        let uploads = Watch(rig.sync.uploads.stream) { $0 == record }
        services.start()
        defer { services.cancelBackgroundWork() }

        #expect(try await uploads.next("在线记录上传") == record)
        #expect(try await store.macOnline(host))

        await clock.waitForSleeper()
        clock.advance(MacPresence.renewal)
        #expect(try await uploads.next("续期的在线记录上传") == record)
        #expect(try await store.macOnline(host))

        rig.wakeCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(try await !store.macOnline(host))
        #expect(try await uploads.next("在线记录上传") == record)
        await clock.waitForSleeper()
        clock.advance(MacPresence.renewal)
        await clock.waitForSleeper()
        #expect(try await !store.macOnline(host))

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(try await uploads.next("在线记录上传") == record)
        #expect(try await store.macOnline(host))
    }

    // MARK: Pi 状态记录

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

        try services.reconcileLaunch()

        let states = Dictionary(uniqueKeysWithValues: try await services.store.allPiSessionStates().map { ($0.sessionID, $0.state) })
        #expect(states == ["old": .known(.ended), "theirs": .known(.thinking)])
    }

    /// 各家接入上桥时都报"现在"（这里的假扩展也是），起点只在桥上定一次，界面与同步记录读的是同一个。
    @Test func 重开后接回的会话沿用原来的起点_看过的不又成有新回复() async throws {
        let past = Date.now.addingTimeInterval(-3600)
        let before = PiStateRecorder(store: services.store, hostID: TestApp.hostID)
        try await before.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: past, busySince: nil))
        try await before.update(sessionID: "s2", state: .thinking, times: PiTimes(stateSince: past, busySince: past))
        let seen = try #require(try await services.store.allPiSessionStates().first { $0.sessionID == "s1" })
        services.settings.markSeen(seen, at: past.addingTimeInterval(1))

        try services.reconcileLaunch()
        let kept = try await rig.host.connect("s1", cwd: "/work/s1")
        let changed = try await rig.host.connect("s2", cwd: "/work/s2")

        let live = try #require(services.pi.session(id: kept.id))
        #expect(live.stateSince == seen.stateSince)
        let row = try #require(PiSessionState.live(live, hostID: TestApp.hostID, projectID: nil, recap: PiRecap(lastReply: "做完了")))
        #expect(!services.settings.isUnread(row))
        #expect(try #require(services.pi.session(id: changed.id)).stateSince > past)
    }

    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        #expect(HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001") == "mac-8644cc63caf7fc7a")
    }
}
#endif
