import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

/// App 层接入同步：启动引擎、镜像状态与问题、激活时立即同步、冲突与决定经 AppServices 交给界面。
struct SyncWiringTests {
    let app = TestApp()
    var services: AppServices { app.services }

    @Test func 启动同步_状态与问题镜像给界面() async throws {
        #expect(services.syncStatus == .starting)  // 引擎确认账号前不是"已同步"
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("app.sync.started == 1") { app.sync.started == 1 }
        #expect(app.sync.started == 1)

        app.sync.emit(SyncState(status: .syncing, issues: []))
        try await eventually("services.syncStatus == .syncing") { services.syncStatus == .syncing }
        #expect(services.syncStatus == .syncing)

        let issue = SyncIssue(recordType: "cards", recordName: "c1", message: "附件记录没有文件，已拒绝")
        app.sync.emit(SyncState(status: .syncing, issues: [issue]))
        try await eventually("services.syncIssues == [issue]") { services.syncIssues == [issue] }
        #expect(services.syncIssues == [issue])

        app.sync.emit(SyncState(status: .syncing, issues: [], alerts: .failed("没有网络")))
        try await eventually("services.alertSubscription == .failed(\"没有网络\")") { services.alertSubscription == .failed("没有网络") }
        #expect(services.alertSubscription == .failed("没有网络"))

        app.sync.emit(SyncState(status: .needsDecision(.accountSwitched), issues: [issue]))
        try await eventually("services.syncStatus == .needsDecision(.accountSwitched)") { services.syncStatus == .needsDecision(.accountSwitched) }
        #expect(services.syncStatus == .needsDecision(.accountSwitched))
    }

    struct NoEntitlement: Error {}

    @Test func 引擎启动失败时进入启动问题_状态写明原因() async throws {
        app.sync.startError.withLock { $0 = NoEntitlement() }
        services.startSync()
        defer { services.cancelBackgroundWork() }

        try await eventually("!services.startupIssues.isEmpty") { !services.startupIssues.isEmpty }

        guard case .syncUnavailable(let message)? = services.startupIssues.first else {
            Issue.record("启动失败没有进入 startupIssues：\(services.startupIssues)")
            return
        }
        #expect(message.contains("NoEntitlement"))
        guard case .unavailable(let reason) = services.syncStatus else {
            Issue.record("\(services.syncStatus)")
            return
        }
        #expect(reason.contains("没能启动"))
    }

    /// 同步一直不返回（引擎队列被占着、网络没有回音）：下拉刷新的圈到时限就停，转着的时候主线程照常响应。
    /// 到时限就停：圈停了、同步仍挂着（停不下来由测试时限抓）。照常响应按主线程上的小睡被耽误多久判断：被占住就是一整个时限，
    /// 门槛取它的五分之一，不按机器空闲时的快慢取。
    @Test(.timeLimit(.minutes(1)))
    func 同步一直不返回时_下拉刷新到时限就停_主线程照常响应() async throws {
        app.sync.syncNowHangs.withLock { $0 = true }
        let refresh = Task { await services.syncNow() }

        var worstDelay = Duration.zero
        let began = ContinuousClock.now
        while began.duration(to: .now) < AppServices.syncWaitLimit {
            let asked = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(50))
            worstDelay = max(worstDelay, asked.duration(to: .now) - .milliseconds(50))
        }
        await refresh.value

        #expect(app.sync.syncNows == 1)
        #expect(worstDelay < AppServices.syncWaitLimit / 5)
    }

    /// 回到前台时正有在等的东西（手机停在 Agent 页、Cue 页，或有话在等回执）：按节奏的拉取随之开始，与立即同步是同一拉，不连拉两次。
    @Test func 应用激活时立即同步_正在等也只拉一次() async {
        let time = ManualTiming()
        let app = TestApp(timing: time.timing)
        app.services.hasOpenDeliveries = true
        await app.services.handleActivation()
        defer { app.services.stopPolling() }
        await time.waitForSleeper()  // 按节奏的拉取已开始、睡在第一个间隔里
        #expect(app.sync.syncNows == 1)
    }

    /// 静默推送把 App 冷启动到后台：推送先于同步启动完到达，等启动完再拉，不空手交还系统；启动后的立即同步就是这一拉，不拉两遍。
    @Test func 冷启动时先到的推送_等同步启动完再拉_只拉一次() async throws {
        app.sync.holdsStart.withLock { $0 = true }
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("开始启动") { app.sync.started == 1 }
        let push = Task { await services.pullForPush() }
        app.sync.startGate.continuation.yield()
        await push.value
        try await eventually("启动完才拉") { services.isSyncingNow == false && app.sync.events.count >= 2 }
        let events = app.sync.events
        #expect(events == ["started", "pull"])
    }

    @Test func 冲突副本经AppServices暴露_选定版本后消失() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let original = try await services.store.createCard(in: nil, body: "原卡")
        let copy = try await services.store.createCard(in: nil, body: "副本")
        #expect(DebugScene.markConflict(copy: copy.id, of: original.id, database: services.location.databaseURL))
        _ = try await services.store.createCard(in: nil, body: "触发一次重读")

        try await eventually("services.conflicts.count == 1") { services.conflicts.count == 1 }
        #expect(services.conflicts.map(\.copy.body) == ["副本"])

        try await services.resolveConflict(copy: copy.id, keep: .original)
        try await eventually("services.conflicts.isEmpty") { services.conflicts.isEmpty }
        #expect(services.conflicts.isEmpty)
    }

    /// 正式组装（`.iCloud`）没有创建引擎时，状态写明原因，不显示成"已同步"。
    /// 真机上的事故：两个入口都绕开了创建引擎的那条路，引擎从未运行，界面却一直是已同步。
    @Test func 正式组装没有创建同步时状态写明原因() {
        let app = TestApp(sync: .iCloud)  // 测试宿主在隔离目录里
        #expect(app.services.sync == nil)
        guard case .unavailable(let reason) = app.services.syncStatus else {
            Issue.record("没有引擎却不是 unavailable：\(app.services.syncStatus)")
            return
        }
        #expect(reason.contains("隔离"))
    }

    @Test func 隔离模式与没有iCloud权限的构建不创建同步() throws {
        let store = services.store
        let isolated = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: "/tmp/isolated-library"])
        let real = try LibraryLocation.resolve(environment: [:], base: .applicationSupport(URL(filePath: "/tmp/support")))

        #expect((try? AppServices.makeSync(store: store, location: isolated, hasCloudKitEntitlement: true).get()) == nil)
        #expect((try? AppServices.makeSync(store: store, location: real, hasCloudKitEntitlement: false).get()) == nil)
        #expect((try? AppServices.makeSync(store: store, location: real, hasCloudKitEntitlement: true).get()) != nil)
    }
}
