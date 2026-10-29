#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// #41：用户打开额度后，失败、过期与换授权不能伪装成新额度；只替换外部 bridge。
struct QuotaFlowTests {
    @Test func 额度失败与过期不变满_换授权不继承旧观测() async throws {
        let app = TestApp()
        let services = app.services!
        let changes = services.pi.changes()
        services.follow(reporting: { .syncUnavailable(String(describing: $0)) }) { try await services.consumePiChanges(changes) }
        defer { services.cancelBackgroundWork() }
        let ext = try await app.host.connect("quota", cwd: "/work/quota")
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "quota" {
                ext?.sendQuota(provider: "anthropic", windows: [
                    ["seconds": 18_000, "used": 0.8, "resetsAt": Date.now.addingTimeInterval(3600).timeIntervalSince1970],
                ], complete: true, scope: "account-a")
            }
            return ["ok": true]
        }
        let workspace = Workspace(services: services)
        await workspace.refreshQuota()
        let observed = try #require(try await eventually(services.store, { try $0.accountQuotas().first }) { $0?.windows.count == 1 })
        #expect(QuotaMeter(observed, at: .now).windows.first?.percent == "20%")

        ext.sendQuota(provider: "anthropic", windows: [], complete: false, scope: "account-a", status: "failed")
        let failed = try #require(try await eventually(services.store, { try $0.accountQuotas().first }) { $0?.status == .failed })
        #expect(QuotaMeter(failed, at: .now).message == "额度查询失败")
        #expect(QuotaMeter(failed, at: .now).windows.isEmpty)
        #expect(failed.observedAt == observed.observedAt)

        ext.sendQuota(provider: "anthropic", windows: [
            ["seconds": 18_000, "used": 0.8, "resetsAt": Date.now.addingTimeInterval(-1).timeIntervalSince1970],
        ], complete: true, scope: "account-a")
        let expired = try #require(try await eventually(services.store, { try $0.accountQuotas().first }) { $0?.status == .observed && $0?.windows.first?.resetsAt ?? .distantFuture < .now })
        #expect(QuotaMeter(expired, at: .now).message == "额度观测已过期，等待更新")
        #expect(QuotaMeter(expired, at: .now).windows.isEmpty)

        ext.sendQuota(provider: "anthropic", windows: [], complete: false, scope: "account-b", status: "unobserved")
        let changed = try #require(try await eventually(services.store, { try $0.accountQuotas().first }) { $0?.account?.scope == "account-b" })
        #expect(QuotaMeter(changed, at: .now).message == "尚未观测到额度")
        #expect(QuotaMeter(changed, at: .now).windows.isEmpty)
        #expect(changed.observedAt == nil)
    }
}
#endif
