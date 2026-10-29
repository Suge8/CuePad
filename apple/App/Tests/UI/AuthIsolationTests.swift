#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Master 终审批准：Claude 授权失效不挡 GPT 发话与模型选择；只替换两个外部服务，Pi、桥、投送与存储照常运行。
struct AuthIsolationTests {
    @Test func Claude授权未返回或已失效_GPT仍能发话换模型_主动查额度明确失败() async throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/auth-isolation.ts")
        let rig = try await HistoryRulesTests.Rig(providerFixture: fixture, otherOAuthProviders: ["anthropic"])
        defer { rig.shutdown() }
        try await rig.store.recordQuota(QuotaReport(provider: "anthropic", windows: [
            QuotaWindow(seconds: 18_000, used: 0.8, resetsAt: .now.addingTimeInterval(3600)),
        ], complete: true, account: PiAccount(kind: .oauth, scope: "another-mac-authorization")), host: "other-mac")
        let id = try await rig.host.open(in: rig.cwd, launchToken: "auth", name: nil, model: nil, thinking: nil)
        let live = try #require(rig.bridge.session(id: id))
        let sessionID = live.sessionID
        let store = rig.store
        let workspace = Workspace(services: rig.services)
        let endpointFile = rig.cwd.deletingLastPathComponent().appending(path: "agent/claude-auth-url")
        let endpoint = try #require(URL(string: String(contentsOf: endpointFile, encoding: .utf8)))
        try await Self.control("expire", at: endpoint)

        // 发话前的命令刷新不能顺带刷新 Claude。若它进入 Claude 门，立即失败并放行清理，不拿墙钟竞速。
        workspace.send("normal", to: AgentTarget(session: sessionID))
        let replied = try await Self.withoutClaude(at: endpoint) {
            _ = try await eventually(store, { try $0.piMessages(of: sessionID) }) { $0.filter { $0.role.known == .pi }.count == 1 }
        }
        try #require(replied, "GPT 应在 Claude 授权返回前完成回答")
        let state = try #require(try await store.allPiSessionStates().first)
        let next = PiModelKey(provider: "openai", id: "echo-next")

        workspace.attempt { _ = try await rig.services.configure(PiConfig(model: next), for: state) }
        let configured = try await Self.withoutClaude(at: endpoint) {
            _ = try await eventually(store, { try $0.allPiSessionStates().first?.model?.key }) { $0 == next }
        }
        try #require(configured, "选择另一个 GPT 模型不能等待 Claude 授权")

        let current = try #require(try await store.allPiSessionStates().first)
        let digest = try await SessionDigest.read(sessionID: sessionID, from: store)
        let claude = try #require(digest.catalog?.models.first { $0.key.provider == "anthropic" })
        #expect(claude.account?.kind == .oauth)
        #expect(claude.account?.scope == nil)
        let quotas = try await store.accountQuotas()
        #expect(!PiModelLabel.title(claude, quotas: quotas, at: .now).contains("%"))
        #expect(try #require(quotas.first { $0.provider == "anthropic" && $0.hostID == TestApp.hostID }).status == .unobserved)

        // 只有主动查询才进入 Claude 授权服务；即使它正在等待，GPT 的发话、设置仍独立。
        let quota = Task { await workspace.refreshQuota() }
        defer { quota.cancel() }
        try await Self.control("entered", at: endpoint)
        workspace.attempt { _ = try await rig.services.configure(PiConfig(model: PiModelKey(provider: "openai", id: "echo")), for: current) }
        _ = try await eventually(store, { try $0.allPiSessionStates().first?.model?.key.id }) { $0 == "echo" }
        workspace.speak("/model openai/echo-next", to: .session(current, mode: .command))
        _ = try await eventually(store, { try $0.allPiSessionStates().first?.model?.key.id }) { $0 == "echo-next" }
        workspace.send("normal", to: AgentTarget(session: sessionID))
        _ = try await eventually(store, { try $0.piMessages(of: sessionID) }) { $0.filter { $0.role.known == .pi }.count == 2 }

        try await Self.control("reject", at: endpoint)
        await quota.value
        #expect(workspace.notice != nil)
        let failed = try #require(try await eventually(store, { try $0.accountQuotas().first { $0.provider == "anthropic" } }) { $0?.status == .failed })
        #expect(failed.observedAt == nil && failed.windows.isEmpty)
        #expect(QuotaMeter(failed, at: .now).message == "额度查询失败")

        workspace.send("normal", to: AgentTarget(session: sessionID))
        let messages = try await eventually(store, { try $0.piMessages(of: sessionID) }) { $0.filter { $0.role.known == .pi }.count == 3 }
        #expect(messages.filter { $0.role.known == .pi }.allSatisfy { $0.text == "PARTIAL_REPLY" })
    }

    private nonisolated static func control(_ action: String, at endpoint: URL) async throws {
        let (_, response) = try await URLSession.shared.data(from: endpoint.appending(path: action))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private nonisolated static func withoutClaude(at endpoint: URL, operation: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await operation(); return true }
            group.addTask { try await control("entered", at: endpoint); return false }
            let completed = try await group.next() == true
            if !completed { try await control("reject", at: endpoint) }
            group.cancelAll()
            return completed
        }
    }
}
#endif
