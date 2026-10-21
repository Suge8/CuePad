#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
import AppKit
@testable import CuePad
@testable import CuePi

extension MacSyncTests {
    // MARK: 订阅额度（Mac 唯一写入，手机只读）

    /// 桥报来的额度一直写进库（`start()` 里同一条路），直到测试结束。
    func recordingQuotas() {
        let changes = services.pi.changes()
        services.follow { try? await self.services.consumePiChanges(changes) }
    }

    static let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    func quota(_ provider: String) async throws -> AccountQuota {
        try await eventually(services.store, { try $0.accountQuotas() }) { $0.contains { $0.provider == provider } }
            .first { $0.provider == provider }!
    }

    /// 回复里顺带报来的额度写进这个账号的记录；手机打开额度视图、数据陈旧时写的刷新请求：Mac 经在线会话里的扩展查一次，查到的写进账号记录，请求按成功写回。
    @Test(.timeLimit(.minutes(1)))
    func 手机的额度刷新请求经在线会话查到_写回额度与成功() async throws {
        recordingQuotas()
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")
        let resetsAt = Self.resetsAt.timeIntervalSince1970
        ext.sendQuota(provider: "anthropic", windows: [["seconds": 18_000, "used": 0.42, "resetsAt": resetsAt, "binding": true]], complete: false)
        let pushed = try await quota("anthropic")
        #expect(pushed.hostID == TestApp.hostID && pushed.windows == [QuotaWindow(seconds: 18_000, used: 0.42, resetsAt: Self.resetsAt, isBinding: true)])

        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "quota" {
                ext?.sendQuota(provider: "openai-codex", windows: [["seconds": 604_800, "used": 0.91, "resetsAt": resetsAt]], complete: true)
            }
            return ["ok": true]
        }

        let request = try await services.store.requestQuotaRefresh(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(ext.received == ["quota"])
        #expect(try await quota("openai-codex").windows == [QuotaWindow(seconds: 604_800, used: 0.91, resetsAt: Self.resetsAt)])
    }

    @Test func 手机的额度刷新请求_这台Mac没有在线会话时按失败写回原因() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestQuotaRefresh(on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.failure == "这台 Mac 上没有在线的 Agent 会话，查不了额度")
        #expect(try await services.store.accountQuotas().isEmpty)
    }
}
#endif
