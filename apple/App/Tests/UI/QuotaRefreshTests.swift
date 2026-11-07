#if os(iOS)
import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 手机上的额度刷新（`AccountQuotas`）：进展页与额度钮出现、打开明细时自动问（`refreshesQuota` 调的就是 `refreshQuota(.automatic)`），明细里的重试是手动。
/// 只问连着能答额度的会话的 Mac；没查到不弹提示，原因进明细，自动刷新冷却内不再问，重试照问。
@MainActor
struct QuotaRefreshTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    private func quotaRequests() async throws -> [DeliveryRequest] {
        try await store.deliveryRequests().filter { $0.mode == .known(.quota) }
    }

    /// 那台 Mac 写过额度、上面只有 Codex 会话（不能答额度）：问哪台的名单为空。
    private func macWithQuota(_ agent: AgentKind) async throws {
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
}
#endif
