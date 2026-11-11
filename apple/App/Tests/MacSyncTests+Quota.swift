#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

@testable import CueBridge

extension MacSyncTests {
    // 订阅额度只有 Mac 写，手机只读

    func recordingQuotas() {
        let changes = services.bridge.changes()
        services.follow { [services] in try? await services.consumeSessionChanges(changes) }
    }

    static let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    func quota(_ provider: String) async throws -> AccountQuota {
        try await eventually(services.store, { try $0.accountQuotas() }) { $0.contains { $0.provider == provider } }
            .first { $0.provider == provider }!
    }

    @Test
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

        #expect(done.failure == "这台 Mac 上没有在线的 Pi 会话")
        #expect(try await services.store.accountQuotas().isEmpty)
    }
}
#endif
