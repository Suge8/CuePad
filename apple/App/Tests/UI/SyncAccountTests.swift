import CloudKit
import CueStore
@testable import CueSync
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SyncAccountTests {
    let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
    /// 账号变化只发给这里起的同步：全进程的通知会叫醒并行的别的测试。
    let accountChanges = NotificationCenter()

    @Test
    func 没登录iCloud时_提示登录_记的不传_登上后自动传出() async throws {
        await cloud.setAccount(.noAccount)
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        try await eventually("提示登录") { services.syncing.state.status == .noAccount }

        let card = try await workspace.createCard(body: "没登录时记的", in: Project.defaultID)
        await services.upload(card.id)
        await services.syncing.syncNow()
        #expect(await !cloud.saved.contains(name(card)))
        #expect(services.syncing.state.status == .noAccount)

        await cloud.setAccount(.available)
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("登上后传出") { await cloud.saved.contains(name(card)) }
    }

    @Test
    func 账号暂时认不了时_提示暂不可用_自己再认_认好后传出() async throws {
        await cloud.setAccount(.temporarilyUnavailable)
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        try await eventually("提示暂不可用") { services.syncing.state.status == .accountUnavailable }

        let card = try await workspace.createCard(body: "认不了时记的", in: Project.defaultID)
        await services.upload(card.id)
        #expect(await !cloud.saved.contains(name(card)))

        await cloud.setAccount(.available)
        try await eventually("认好后传出") { await cloud.saved.contains(name(card)) }
        try await eventually("不再提示") { services.syncing.state.status == .idle }
    }

    @Test
    func 同步着时账号认不清_认清之前不传_还是原账号就放开() async throws {
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        let before = try await workspace.createCard(body: "认不清之前记的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(name(before)) }

        await cloud.setAccount(.couldNotDetermine)
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("提示暂不可用") { services.syncing.state.status == .accountUnavailable }
        let waiting = try await workspace.createCard(body: "认不清时记的", in: Project.defaultID)
        await services.upload(waiting.id)
        #expect(await !cloud.saved.contains(name(waiting)))

        await cloud.setAccount(.available)
        try await eventually("认清后传出") {
            await services.syncing.syncNow()
            return await cloud.saved.contains(name(waiting))
        }
        try await eventually("回到已同步") { services.syncing.state.status == .idle }  // 界面的状态由跟随者异步抄过来
    }

    @Test
    func 关着时换了账号_再打开就等你决定_决定前不传() async throws {
        let app = start()
        let before = try await Workspace(services: app.services).createCard(body: "换账号前记的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(name(before)) }
        await app.services.sync?.stop()

        await cloud.signIn("另一个账号")
        let services = app.relaunch()
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("要你决定") { services.syncing.state.status == .needsDecision(.accountSwitched) }
        let waiting = try await Workspace(services: services).createCard(body: "决定之前记的", in: Project.defaultID)
        await services.upload(waiting.id)
        await services.syncing.syncNow()
        #expect(await !cloud.saved.contains(name(waiting)))

        try await services.resolveSync(.uploadLocal)
        try await eventually("传给新账号") { await cloud.saved.contains(name(waiting)) }
    }

    #if os(iOS)
    @Test
    func 挂起期间换了账号没收到通知_回到前台先认出来_旧数据不传() async throws {
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        let synced = try await workspace.createCard(body: "同步过的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(name(synced)) }

        await cloud.setUploadsFail(true)
        let pending = try await workspace.createCard(body: "挂起前没传出去的", in: Project.defaultID)
        await services.upload(pending.id)
        await cloud.signIn("另一个账号")
        await cloud.setUploadsFail(false)

        await services.handleActivation()
        try await eventually("认出新账号、要你决定") { services.syncing.state.status == .needsDecision(.accountSwitched) }
        await services.upload(pending.id)
        #expect(await !cloud.saved.contains(name(pending)))
    }

    @Test
    func 挂起前的认账号还在路上_回到前台另认一次() async throws {
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        let synced = try await workspace.createCard(body: "同步过的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(name(synced)) }

        await cloud.setAccount(nil)
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("挂起前那次在认") { await cloud.accountChecks >= 2 }
        let pending = try await workspace.createCard(body: "认清之前记的", in: Project.defaultID)
        await cloud.signIn("另一个账号")
        await cloud.setAccount(.available)

        let began = ContinuousClock.now
        await services.handleActivation()
        #expect(ContinuousClock.now - began < .seconds(5))  // 沿用挂起前那次的，要等它到请求时限（15 秒）
        try await eventually("要你决定") { services.syncing.state.status == .needsDecision(.accountSwitched) }
        await services.upload(pending.id)
        #expect(await !cloud.saved.contains(name(pending)))
    }
    #endif

    private func start() -> TestApp {
        let app = TestApp(sync: .built { [cloud, accountChanges] in CloudSync(store: $0, accountChanges: accountChanges) { cloud } })
        app.services.startSync()
        return app
    }

    private func name(_ card: Card) -> String { card.id.uuidString.lowercased() }
}
