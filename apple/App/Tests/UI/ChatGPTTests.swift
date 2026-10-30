#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// #41：从用户的刷新与发送入口，经真实隔离 Pi/bridge 入库；仅模型服务是替身。
struct ChatGPTTests {
    private func rig(oauth: Bool = true) async throws -> HistoryRulesTests.Rig {
        try await HistoryRulesTests.Rig(providerFixture: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/chatgpt.ts"), oauth: oauth)
    }

    @Test(arguments: [true, false]) func 登录路线决定套餐或API计费_不借Codex额度(oauth: Bool) async throws {
        let rig = try await rig(oauth: oauth)
        defer { rig.shutdown() }
        try await rig.store.recordQuota(QuotaReport(provider: "openai-codex", windows: [
            QuotaWindow(seconds: 604_800, used: 0.91, resetsAt: .now.addingTimeInterval(3600)),
        ], complete: true, account: PiAccount(kind: .oauth, scope: "another-codex-authorization")), host: TestApp.hostID)
        _ = try await rig.host.open(in: rig.cwd, launchToken: "quota", name: nil, model: nil, thinking: nil)
        let records = try await eventually(rig.store, { try $0.allPiSessionStates() }) { $0.first?.model != nil }
        let model = try #require(records.first?.model)
        let workspace = Workspace(services: rig.services)

        await workspace.refreshQuota()

        let quotas = try await eventually(rig.store, { try $0.accountQuotas() }) { $0.contains { $0.provider == "openai" } }
        let shown = QuotaMeter(try #require(quotas.first { $0.provider == "openai" }), at: .now)
        #expect(shown.windows.isEmpty)
        #expect(!PiModelLabel.title(model, quotas: quotas, at: .now).contains("%"))
        if oauth {
            #expect(model.account?.label(provider: model.key.provider) == "使用 ChatGPT 套餐")
            #expect(shown.account == "使用 ChatGPT 套餐")
            #expect(shown.message == "ChatGPT 暂不提供额度数据")
            #expect(shown.usageURL?.absoluteString == "https://chatgpt.com/settings/usage")
            #expect(workspace.notice == nil)
        } else {
            #expect(model.account?.label(provider: model.key.provider) == "OpenAI API 按量计费")
            #expect(shown.account == "OpenAI API 按量计费")
            #expect(shown.usageURL == nil)
        }
    }

    @Test(arguments: ["[[length]]", "[[quota]]", "[[403]]", "normal"])
    func 回答结果保留部分文字_截断不完成_限额能管理_权限不误报登录(prompt: String) async throws {
        let rig = try await rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "reply", name: nil, model: nil, thinking: nil)
        let live = try #require(rig.bridge.session(id: id))
        let workspace = Workspace(services: rig.services)

        workspace.send(prompt, to: AgentTarget(session: live.sessionID))

        let messages = try await eventually(rig.store, { try $0.piMessages(of: live.sessionID) }) { $0.contains { $0.text == "PARTIAL_REPLY" } }
        let state = try #require(try await eventually(rig.store, { try $0.allPiSessionStates().first }) {
            $0?.lastReply == "PARTIAL_REPLY" && $0?.state.known?.isWorking == false
        })
        #expect(state.lastReply == "PARTIAL_REPLY")
        let request = try #require(try await rig.store.deliveryRequests(toSession: live.sessionID).last)
        let delivery = try await rig.store.outcome(of: request)
        let digest = try await SessionDigest.read(sessionID: live.sessionID, from: rig.store)
        let realtime = try #require(digest.live(rig.bridge.session(id: id), hostID: TestApp.hostID, project: nil).session)
        #expect(workspace.shownInHeader(realtime, delivery: nil).label == workspace.shownInHeader(state, delivery: nil).label)
        #expect(realtime.usageURL == state.usageURL)
        #expect(workspace.shownInHeader(state, delivery: delivery).status == workspace.shownInHeader(state, delivery: nil).status)
        #expect(workspace.shownInHeader(realtime, delivery: delivery).status == workspace.shownInHeader(state, delivery: nil).status)
        if prompt == "normal" {
            #expect(state.state == .known(.settled))
        } else {
            #expect(state.state == .known(.error))
        }
        if prompt == "[[length]]" {
            #expect(state.detail == "回答未完成：达到输出长度上限")
            #expect(workspace.shownInHeader(state, delivery: nil).label == "回答未完成")
            #expect(messages.contains { $0.notice == .truncated })
            let indexed = try #require(try await rig.store.piSession(live.sessionID))
            let history = try PiHistory.index(file: URL(filePath: indexed.path), agent: .pi, from: nil, files: rig.store.files)
            #expect(history.messages.contains { $0.notice == .truncated })
            #expect(history.messages.contains { $0.text == "PARTIAL_REPLY" })
        }
        if prompt == "[[quota]]" {
            #expect(workspace.shownInHeader(state, delivery: nil).label == "达到用量限制")
            #expect(state.usageURL?.absoluteString == "https://chatgpt.com/settings/usage")
        }
        if prompt == "[[403]]" {
            #expect(state.failure?.known == .other)
            #expect(state.usageURL == nil)
        }
    }
}
#endif
