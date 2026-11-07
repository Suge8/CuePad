#if os(iOS)
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad
@testable import CueStore

/// 手机上的额度刷新（`AccountQuotas`）：进展页与额度钮出现、打开明细时自动问（`refreshesQuota` 调的就是 `refreshQuota(.automatic)`），明细里的重试是手动。
/// 只问连着能答额度的会话的 Mac；没查到不弹提示，原因进明细，自动刷新冷却内不再问，重试照问。
@MainActor
struct QuotaRefreshTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    private func quotaRequests(in app: TestApp? = nil) async throws -> [DeliveryRequest] {
        try await (app ?? self.app).services.store.deliveryRequests().filter { $0.mode == .known(.quota) }
    }

    /// 那台 Mac（mac-x）写过额度、上面有一个 `agent` 的在线会话。
    private func macWithQuota(_ agent: AgentKind, in app: TestApp? = nil) async throws {
        let app = app ?? self.app, services = app.services!, store = services.store
        try await store.recordQuota(
            QuotaReport(provider: "anthropic", windows: [], complete: true, account: PiAccount(kind: .oauth, scope: "a")), host: "mac-x")
        try await app.runtimeRecorder(on: "mac-x").update(sessionID: "s-\(agent.rawValue)", state: .thinking, title: "atlas", agent: agent)
        services.startLiveSessions()
        services.startAccountQuotas()
        try await eventually("会话与额度到界面") { !services.liveSessions.live.isEmpty && !services.accountQuotas.items.isEmpty }
    }

    @Test func Mac上没有能答额度的会话时_进展页不发请求_不弹提示() async throws {
        defer { services.cancelBackgroundWork() }
        try await macWithQuota(.codex)
        let workspace = Workspace(services: services)

        #expect(await services.refreshQuota(.automatic) == nil)

        #expect(try await quotaRequests().isEmpty)
        #expect(services.accountQuotas.phase == .idle)
        #expect(workspace.notice == nil)
    }

    @Test func 没查到写进明细不弹提示_冷却内自动不再问_重试照问() async throws {
        defer { services.cancelBackgroundWork() }
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
        defer { Task { await mac.stop() } }
        let workspace = Workspace(services: services)

        let failure = await services.refreshQuota(.automatic)
        #expect(failure?.text == "这台 Mac 上没有在线的 Pi 会话")
        guard case .failed(let reason, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("明细里该有没查到的原因：\(services.accountQuotas.phase)")
            return
        }
        #expect(reason.text == "这台 Mac 上没有在线的 Pi 会话")
        #expect(workspace.notice == nil)

        // 再进进展页、再打开明细：冷却内不再问
        #expect(await services.refreshQuota(.automatic) == nil)
        #expect(try await quotaRequests().count == 1)

        // 明细里点重试
        #expect(await services.refreshQuota(.manual) == nil)
        #expect(try await quotaRequests().count == 2)
        #expect(services.accountQuotas.phase == .idle)
        #expect(workspace.notice == nil)
    }

    @Test func 页面取消不取消查询_同来源并发合并_换来源不受旧冷却限制() async throws {
        defer { services.cancelBackgroundWork() }
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

        // 新 Mac 连上后立即自动查；旧来源的失败冷却不能拦住这批新来源。
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

    /// Mac 一直不领取：请求到期后手机按未确认收尾，明细写没查到的原因、不弹提示；重试再发一条，这次 Mac 领了、查到。
    @Test func Mac不领取_请求到期后明细显示没查到_可重试() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), services = app.services!, store = services.store
        defer { services.cancelBackgroundWork() }
        try await macWithQuota(.pi, in: app)
        let workspace = Workspace(services: services)

        let query = Task { await services.refreshQuota(.automatic) }
        let request = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.quota) } }) { $0 != nil })
        // 服务器真实收下，上传回执带回派发锚点；Mac 不领取，走过派发期限与回执窗口。
        let row = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
        try await store.markPushed([(row, Data(), clock.now)])
        clock.advance(.seconds(DeliveryRequest.phaseLimit + Speech.receiptLimit + 1))

        #expect(await query.value == Speech.unconfirmedReason)
        guard case .failed(let reason, ["mac-x"], _) = services.accountQuotas.phase else {
            Issue.record("明细里该有没查到的原因：\(services.accountQuotas.phase)")
            return
        }
        #expect(reason == Speech.unconfirmedReason)
        #expect(workspace.notice == nil)

        // 明细里点重试：不受冷却限制，再发一条；这次 Mac 领了、查到
        let retry = Task { await services.refreshQuota(.manual) }
        let next = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.quota) && $0.id != request.id } }) { $0 != nil })
        let retried = try #require(try await store.syncRow(recordName: next.id.uuidString.lowercased()))
        try await store.markPushed([(retried, Data(), clock.now)])
        let mac = DeliveryExecutor(store: store, hostID: "mac-x", timing: clock.timing, onIssue: { Issue.record("\($0)") }) { request, _ in
            request.mode == .known(.quota) ? .succeeded : .failed(ShownText("不该有别的请求"))
        }
        try await mac.start()
        defer { Task { await mac.stop() } }
        #expect(await retry.value == nil)
        #expect(try await quotaRequests(in: app).count == 2)
        #expect(services.accountQuotas.phase == .idle)
        #expect(workspace.notice == nil)
    }
}
#endif
