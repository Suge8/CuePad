import CloudKit
import CueStore
@testable import CueSync
import Foundation
import Testing
@testable import CuePad

/// 认不清 iCloud 账号时：真实的同步代码连内存里的 iCloud 替身，从 AppServices 启动。认清之前记的照记、不上传，
/// 设置里说为什么；认清之后不用用户再做什么，记下的就传上去。
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
        try await eventually("提示登录") { services.syncState.status == .noAccount }

        let card = try await workspace.createCard(body: "没登录时记的", in: Project.defaultID)
        await services.upload(card.id)
        await services.syncNow()
        #expect(await !cloud.saved.contains(name(card)))
        #expect(services.syncState.status == .noAccount)

        await cloud.setAccount(.available)
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("登上后传出") { await cloud.saved.contains(name(card)) }
    }

    /// 暂时认不了不等账号变化：同步自己按退避再认（第一次隔 1–2 秒）。
    @Test
    func 账号暂时认不了时_提示暂不可用_自己再认_认好后传出() async throws {
        await cloud.setAccount(.temporarilyUnavailable)
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        try await eventually("提示暂不可用") { services.syncState.status == .accountUnavailable }

        let card = try await workspace.createCard(body: "认不了时记的", in: Project.defaultID)
        await services.upload(card.id)
        #expect(await !cloud.saved.contains(name(card)))

        await cloud.setAccount(.available)
        try await eventually("认好后传出") { await cloud.saved.contains(name(card)) }
        try await eventually("不再提示") { services.syncState.status == .idle }
    }

    /// 同步着时账号变了、却认不清此刻是哪个账号：可能已是另一个账号，认清之前不传；认清还是原来那个就放开，不用等你决定。
    @Test
    func 同步着时账号认不清_认清之前不传_还是原账号就放开() async throws {
        let app = start()
        let (services, workspace) = (app.services!, Workspace(services: app.services))
        defer { services.cancelBackgroundWork() }
        let before = try await workspace.createCard(body: "认不清之前记的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(name(before)) }

        await cloud.setAccount(.couldNotDetermine)
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("提示暂不可用") { services.syncState.status == .accountUnavailable }
        let waiting = try await workspace.createCard(body: "认不清时记的", in: Project.defaultID)
        await services.upload(waiting.id)
        #expect(await !cloud.saved.contains(name(waiting)))

        await cloud.setAccount(.available)
        try await eventually("认清后传出") {
            await services.syncNow()
            return await cloud.saved.contains(name(waiting))
        }
        #expect(services.syncState.status == .idle)
    }

    /// App 没开着时换了 iCloud 账号：再打开，第一次认账号就停下等你决定，决定之前记的不传；选上传本机后传给新账号。
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
        try await eventually("要你决定") { services.syncState.status == .needsDecision(.accountSwitched) }
        let waiting = try await Workspace(services: services).createCard(body: "决定之前记的", in: Project.defaultID)
        await services.upload(waiting.id)
        await services.syncNow()
        #expect(await !cloud.saved.contains(name(waiting)))

        try await services.resolveSync(.uploadLocal)
        try await eventually("传给新账号") { await cloud.saved.contains(name(waiting)) }
    }

    /// 认账号一直没有回音时停下同步（Mac 退出收尾的最后一步）：当场返回，在等的立即同步、取文件、门铃的密钥都得到"没在同步"。
    @Test
    func 认账号没有回音时停下_在等的都当场返回() async throws {
        await cloud.setAccount(nil)
        let app = TestApp()
        let sync = CloudSync(store: app.services.store) { [cloud] in cloud }
        let starting = Task { await sync.start() }
        let pulling = Task { try await sync.syncNow() }
        let fetching = Task { try await sync.fetchFile("missing") }
        let secret = Task { try await sync.relaySecret() }

        try await eventually("在认账号") { await cloud.accountChecks == 1 }
        await sync.stop()
        await starting.value
        #expect(try await pulling.value == .incomplete)
        await #expect(throws: FileFetchFailure.notSyncing) { try await fetching.value }
        await #expect(throws: CancellationError.self) { try await secret.value }
    }

    private func start() -> TestApp {
        let app = TestApp(sync: .built { [cloud, accountChanges] in CloudSync(store: $0, accountChanges: accountChanges) { cloud } })
        app.services.startSync()
        return app
    }

    private func name(_ card: Card) -> String { card.id.uuidString.lowercased() }
}
