import CueStore
import CueSync
import Foundation
import SQLite3
import Testing
@testable import CuePad

/// App 层接入同步：启动引擎、镜像状态与问题、激活时立即同步、冲突与决定经 AppServices 交给界面。
@MainActor
struct SyncWiringTests {
    let app = TestApp()
    var services: AppServices { app.services }

    private func wait(for condition: @MainActor () -> Bool) async {
        await eventually(condition)
    }

    /// Mac：有会话连着或有本机待执行的请求就每 2 秒，闲着时也不放慢（没有推送可靠性的数据前不拿延迟换请求数），都没有就不拉。
    @Test func Mac主动拉取的节奏_有会话或请求就是2秒() {
        let every2 = SyncPoller.Cadence(.every(.seconds(2)))
        #expect(SyncPoller.Cadence.mac(hasOpenDeliveries: false, hasSessions: false) == nil)
        #expect(SyncPoller.Cadence.mac(hasOpenDeliveries: false, hasSessions: true) == every2)
        #expect(SyncPoller.Cadence.mac(hasOpenDeliveries: true, hasSessions: false) == every2)
        #expect(SyncPoller.Cadence.mac(hasOpenDeliveries: true, hasSessions: true) == every2)
    }

    @Test func 启动同步引擎_状态与问题镜像给界面() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        await wait { app.sync.started == 1 }
        #expect(app.sync.started == 1)

        app.sync.emit(SyncState(status: .syncing, issues: []))
        await wait { services.syncStatus == .syncing }
        #expect(services.syncStatus == .syncing)

        let issue = SyncIssue(recordType: "cards", recordName: "c1", message: "附件记录没有文件，已拒绝")
        app.sync.emit(SyncState(status: .syncing, issues: [issue]))
        await wait { services.syncIssues == [issue] }
        #expect(services.syncIssues == [issue])

        app.sync.emit(SyncState(status: .syncing, issues: [], alerts: .failed("没有网络")))
        await wait { services.alertSubscription == .failed("没有网络") }
        #expect(services.alertSubscription == .failed("没有网络"))

        app.sync.emit(SyncState(status: .needsDecision(.accountSwitched), issues: [issue]))
        await wait { services.syncStatus == .needsDecision(.accountSwitched) }
        #expect(services.syncStatus == .needsDecision(.accountSwitched))
    }

    struct NoEntitlement: Error {}

    @Test func 引擎启动失败时进入启动问题() async throws {
        app.sync.startError.withLock { $0 = NoEntitlement() }
        services.startSync()
        defer { services.cancelBackgroundWork() }

        await wait { !services.startupIssues.isEmpty }

        guard case .syncUnavailable(let message)? = services.startupIssues.first else {
            Issue.record("启动失败没有进入 startupIssues：\(services.startupIssues)")
            return
        }
        #expect(message.contains("NoEntitlement"))
    }

    @Test func 应用激活时立即同步() async {
        await services.handleActivation()
        #expect(app.sync.syncNows == 1)
    }

    @Test func 界面的同步决定交给引擎() async throws {
        try await services.resolveSync(.eraseLocal)
        #expect(app.sync.resolutions == ["eraseLocal"])
    }

    @Test func 冲突副本经AppServices暴露_选定版本后消失() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let original = try await services.store.createCard(in: nil, body: "原卡")
        let copy = try await services.store.createCard(in: nil, body: "副本")
        try markConflict(copy: copy.id, of: original.id)
        _ = try await services.store.createCard(in: nil, body: "触发一次重读")

        await wait { services.conflicts.count == 1 }
        #expect(services.conflicts.map(\.copy.body) == ["副本"])

        try await services.resolveConflict(copy: copy.id, keep: .original)
        await wait { services.conflicts.isEmpty }
        #expect(services.conflicts.isEmpty)
    }

    /// 正式组装（`.iCloud`）没有创建引擎时，状态写明原因，不显示成"已同步"。
    /// 真机上的事故：两个入口都绕开了创建引擎的那条路，引擎从未运行，界面却一直是已同步。
    @Test func 正式组装没有创建同步引擎时状态写明原因() {
        let app = TestApp(sync: .iCloud)  // 测试宿主在隔离目录里
        #expect(app.services.sync == nil)
        guard case .unavailable(let reason) = app.services.syncStatus else {
            Issue.record("没有引擎却不是 unavailable：\(app.services.syncStatus)")
            return
        }
        #expect(reason.contains("隔离"))
    }

    @Test func 有引擎时启动前是正在连接_不是已同步() {
        #expect(services.syncStatus == .starting)
    }

    @Test func 引擎没能启动时状态也写明原因() async throws {
        app.sync.startError.withLock { $0 = NoEntitlement() }
        services.startSync()
        defer { services.cancelBackgroundWork() }
        await wait { if case .unavailable = services.syncStatus { true } else { false } }
        guard case .unavailable(let reason) = services.syncStatus else {
            Issue.record("\(services.syncStatus)")
            return
        }
        #expect(reason.contains("没能启动"))
    }

    @Test func 隔离模式与没有iCloud权限的构建不创建同步引擎() throws {
        let store = services.store
        let isolated = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: "/tmp/isolated-library"])
        let real = try LibraryLocation.resolve(environment: [:], base: .applicationSupport(URL(filePath: "/tmp/support")))

        #expect((try? AppServices.makeSync(store: store, location: isolated, hasCloudKitEntitlement: true).get()) == nil)
        #expect((try? AppServices.makeSync(store: store, location: real, hasCloudKitEntitlement: false).get()) == nil)
        #expect((try? AppServices.makeSync(store: store, location: real, hasCloudKitEntitlement: true).get()) != nil)
    }

    /// 库里没有创建冲突副本的公开入口（由同步引擎产生），测试直接写库文件。
    private func markConflict(copy: UUID, of original: UUID) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(services.location.databaseURL.path, &handle) == SQLITE_OK else { throw SyncTestError() }
        let sql = "UPDATE cards SET conflictOf = '\(original.uuidString.lowercased())' WHERE id = '\(copy.uuidString.lowercased())'"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SyncTestError() }
    }

    struct SyncTestError: Error {}
}
