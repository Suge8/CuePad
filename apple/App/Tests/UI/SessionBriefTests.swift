#if os(macOS)
import CueBridge
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// CuePad 起的会话在系统提示里带着那段指引（写着 App 里 cuepad 的绝对路径），与接没接入无关：真 Agent 连假模型，看模型收到的系统提示。
@MainActor
@Suite(.releasesLibraries, .timeLimit(.minutes(4)))
struct SessionBriefTests {
    private func briefed(_ model: FakeModel, _ word: String) -> Bool {
        model.requests.contains { request in
            request.prompt.contains(word) && request.system.contains(" show <文件…> --title <标题>…") && request.system.contains("Helpers/cuepad show --help")
        }
    }

    @Test(.pinnedPi) func Pi托管会话的系统提示带着指引() async throws {
        let rig = try await HistoryRulesTests.Rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "brief", name: nil, model: nil, thinking: nil)
        let sessionID = try #require(rig.bridge.session(id: id)).sessionID

        Workspace(services: rig.services).send("看看首页", to: AgentTarget(session: sessionID))

        try await eventually("模型收到了带指引的系统提示") { briefed(rig.model, "看看首页") }
    }

    @Test(.enabled(if: PinnedAgent.claude.uncovered == nil, Comment(rawValue: PinnedAgent.claude.uncovered ?? "")))
    func ClaudeCode托管会话没接入也带着指引() async throws {
        try await ClaudeRig.run { rig in
            await rig.services.disconnectAgent(.claudeCode)
            let id = try await rig.runtime.open(in: rig.work, launchToken: "brief", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(rig.bridge.session(id: id)).sessionID

            Workspace(services: rig.services).send("看看首页", to: AgentTarget(session: sessionID))

            try await eventually("模型收到了带指引的系统提示") { briefed(rig.model, "看看首页") }
        }
    }
}
#endif
