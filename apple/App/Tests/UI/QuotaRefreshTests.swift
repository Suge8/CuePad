#if os(iOS)
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad
@testable import CueStore
@testable import CueSync

@MainActor
@Suite(.releasesLibraries)
struct QuotaRefreshTests {
    let app = TestApp(sync: .built { CloudSync.simulated(store: $0, peerFloor: CueStore.peerFloor) })
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    private func quotaRequests(in app: TestApp? = nil) async throws -> [DeliveryRequest] {
        try await (app ?? self.app).services.store.deliveryRequests().filter { $0.mode == .known(.quota) }
    }

    private func macWithQuota(_ agent: AgentKind, in app: TestApp? = nil) async throws {
        let app = app ?? self.app, services = app.services!, store = services.store
        try await store.recordQuota(
            QuotaReport(provider: "anthropic", windows: [], complete: true, account: PiAccount(kind: .oauth, scope: "a")), host: "mac-x")
        try await app.runtimeRecorder(on: "mac-x").update(sessionID: "s-\(agent.rawValue)", state: .thinking, title: "atlas", agent: agent)
        await services.sync?.start()
        services.startLiveSessions()
        services.startAccountQuotas()
        try await eventually("会话与额度到界面") { !services.liveSessions.live.isEmpty && !services.accountQuotas.items.isEmpty }
    }

    @Test func Mac上没有能答额度的会话时_自动刷新不发请求() async throws {
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.codex)

        #expect(await services.refreshQuota(.automatic) == nil)

        #expect(try await quotaRequests().isEmpty)
        #expect(services.accountQuotas.phase == .idle)
    }

    @Test func 没查到保留原因_冷却内自动不再问_重试照问() async throws {
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.pi)
        #expect(services.quotaRefreshKey == ["mac-x"])
        // 演那台 Mac：第一次按会话还没连好写回失败，之后查到
        let answered = Mutex(0)
        let mac = DeliveryExecutor(store: store, hostID: "mac-x", onIssue: { _ in }) { _, _ in
            answered.withLock { count in
                count += 1
                return count == 1 ? .failed(ShownText("这台 Mac 上没有在线的 Pi 会话")) : .succeeded
            }
        }
        try await mac.start()
        defer { await mac.stop() }

        let failure = await services.refreshQuota(.automatic)
        #expect(failure?.text == "这台 Mac 上没有在线的 Pi 会话")
        guard case .failed(let reason, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("明细里该有没查到的原因：\(services.accountQuotas.phase)")
            return
        }
        #expect(reason.text == "这台 Mac 上没有在线的 Pi 会话")

        #expect(await services.refreshQuota(.automatic) == nil)
        #expect(try await quotaRequests().count == 1)

        #expect(await services.refreshQuota(.manual) == nil)
        #expect(try await quotaRequests().count == 2)
        #expect(services.accountQuotas.phase == .idle)
    }

    @Test func 页面取消不取消查询_同来源并发合并_换来源不受旧冷却限制() async throws {
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.pi)
        let gate = AsyncStream<Void>.makeStream()
        let attempts = Mutex(0)
        let mac = DeliveryExecutor(store: store, hostID: "mac-x", onIssue: { Issue.record("\($0)") }) { _, _ in
            let first = attempts.withLock { count in count += 1; return count == 1 }
            if first {
                for await _ in gate.stream { break }
                return .failed(ShownText("这台 Mac 上没有在线的 Pi 会话"))
            }
            return .succeeded
        }
        try await mac.start()
        let page = Task { await services.refreshQuota(.automatic) }
        try await eventually("Mac 接到查询") { attempts.withLock { $0 } == 1 }
        var entered = false
        let details = Task {
            entered = true
            return await services.refreshQuota(.manual)
        }
        try await eventually("明细加入正在查询的这次") { entered }
        page.cancel()
        gate.continuation.finish()
        let failure = await page.value
        #expect(failure?.text == "这台 Mac 上没有在线的 Pi 会话")
        #expect(await details.value == failure)
        #expect(try await quotaRequests().count == 1)
        guard case .failed(_, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("页面取消后仍应记下这次失败")
            await mac.stop()
            return
        }
        #expect(await services.refreshQuota(.automatic) == nil)
        #expect(try await quotaRequests().count == 1)

        try await app.runtimeRecorder(on: "mac-y").update(sessionID: "new-pi", state: .thinking, title: "new", agent: .pi)
        try await eventually("来源变为两台 Mac") { services.quotaRefreshKey == ["mac-x", "mac-y"] }
        let other = DeliveryExecutor(store: store, hostID: "mac-y", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
        try await other.start()
        #expect(await services.refreshQuota(.automatic) == nil)
        #expect(try await quotaRequests().count == 3)
        #expect(services.accountQuotas.phase == .idle)
        await mac.stop()
        await other.stop()
    }

    @Test(arguments: [false, true]) func 查询途中来源变化_取消等待页不启动新查询_冷却对应实际来源(cancelPage: Bool) async throws {
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.pi)
        let gate = AsyncStream<Void>.makeStream()
        let attempts = Mutex(0)
        let firstMac = DeliveryExecutor(store: store, hostID: "mac-x", onIssue: { Issue.record("\($0)") }) { _, _ in
            let first = attempts.withLock { count in count += 1; return count == 1 }
            if first { for await _ in gate.stream { break } }
            return .succeeded
        }
        let secondMac = DeliveryExecutor(store: store, hostID: "mac-y", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
        let lastMac = DeliveryExecutor(store: store, hostID: "mac-z", onIssue: { Issue.record("\($0)") }) { _, _ in .failed(ShownText("最后连上的 Mac 查询失败")) }
        try await firstMac.start()
        try await secondMac.start()
        try await lastMac.start()
        defer {
            gate.continuation.finish()
            Task { await firstMac.stop(); await secondMac.stop(); await lastMac.stop() }
        }
        let first = Task { await services.refreshQuota(.automatic) }
        try await eventually("第一轮查询已交给 Mac") { attempts.withLock { $0 } == 1 }
        try await app.runtimeRecorder(on: "mac-y").update(sessionID: "second-pi", state: .thinking, title: "second", agent: .pi)
        try await eventually("第二台 Mac 到达界面") { services.quotaRefreshKey == ["mac-x", "mac-y"] }
        var entered = false
        let waiting = Task {
            entered = true
            return await services.refreshQuota(.automatic)
        }
        try await eventually("来源改变的页面已开始等待") { entered }
        if cancelPage { waiting.cancel() }
        try await app.runtimeRecorder(on: "mac-z").update(sessionID: "last-pi", state: .thinking, title: "last", agent: .pi)
        try await eventually("最后一台 Mac 到达界面") { services.quotaRefreshKey == ["mac-x", "mac-y", "mac-z"] }
        gate.continuation.finish()
        #expect(await first.value == nil)
        let result = await waiting.value
        let requests = try await quotaRequests()
        if cancelPage {
            #expect(result == nil)
            #expect(requests.count == 1)
            #expect(services.accountQuotas.phase == .idle)
        } else {
            #expect(result?.text == "最后连上的 Mac 查询失败")
            #expect(requests.count == 4)
            #expect(Set(requests.map(\.hostID)) == ["mac-x", "mac-y", "mac-z"])
            #expect(await services.refreshQuota(.automatic) == nil)
            #expect(try await quotaRequests().count == 4, "刚查过的实际来源失败后应冷却，不能再发一批")
        }
    }

    @Test func 离线未确认上传就结束刷新_联网后重试复用原请求() async throws {
        let cloud = ReceiptTests.WeakCloud()
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!, store = services.store
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.pi, in: app)
        await cloud.setDown(true)

        let failure = await services.refreshQuota(.automatic)
        #expect(failure?.text == "请求尚未确认上传，联网后可重试")
        let request = try #require(try await quotaRequests(in: app).first)
        #expect(request.serverAt == nil)
        #expect(request.status == .known(.pending))
        #expect(await cloud.holds(request.id) == false)
        guard case .failed(let reason, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("未确认上传应结束本次刷新并保留原因")
            return
        }
        #expect(reason == failure)

        await cloud.setDown(false)
        let retry = Task { await services.refreshQuota(.manual) }
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.serverAt }) { $0 != nil }
        #expect(await cloud.holds(request.id))
        #expect(try await quotaRequests(in: app).map(\.id) == [request.id])
        try await cloud.macAnswers(request.id)
        _ = try await services.sync?.syncNow()
        #expect(await retry.value == nil)
        #expect(services.accountQuotas.phase == .idle)
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.succeeded))
        #expect(try await quotaRequests(in: app).map(\.id) == [request.id])
    }

    @Test func Mac不领取_请求到期后明细显示没查到_可重试() async throws {
        let clock = ManualTiming()
        let cloud = SimulatedCloud(now: { clock.now })
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing)
        let services = app.services!, store = services.store
        defer { services.cancelBackgroundWork(); Task { await services.sync?.stop() } }
        try await macWithQuota(.pi, in: app)

        let query = Task { await services.refreshQuota(.automatic) }
        let request = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.quota) } }) { $0 != nil })
        // 服务器真实收下，上传回执带回派发锚点；Mac 不领取，走过派发期限与回执窗口。
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.serverAt }) { $0 != nil }
        clock.advance(.seconds(DeliveryRequest.phaseLimit + Speech.receiptLimit + 1))

        #expect(await query.value == Speech.unconfirmedReason)
        guard case .failed(let reason, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("明细里该有没查到的原因：\(services.accountQuotas.phase)")
            return
        }
        #expect(reason == Speech.unconfirmedReason)

        let retry = Task { await services.refreshQuota(.manual) }
        let next = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.quota) && $0.id != request.id } }) { $0 != nil })
        _ = try await eventually(store, { try $0.deliveryRequest(next.id)?.serverAt }) { $0 != nil }
        let mac = DeliveryExecutor(store: store, hostID: "mac-x", timing: clock.timing, onIssue: { Issue.record("\($0)") }) { request, _ in
            request.mode == .known(.quota) ? .succeeded : .failed(ShownText("不该有别的请求"))
        }
        try await mac.start()
        defer { await mac.stop() }
        #expect(await retry.value == nil)
        #expect(try await quotaRequests(in: app).count == 2)
        #expect(services.accountQuotas.phase == .idle)
    }
}
#endif
