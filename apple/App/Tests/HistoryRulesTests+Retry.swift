#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

extension HistoryRulesTests {
    /// 出错后从 `Workspace.retry` 重跑，端到端用真实 Pi：会话回到在跑、歇下；对话里不多一句话、不写发送记录，只多出新的回答。
    @Test func 出错后重试_对话只多出新的回答_会话歇下() async throws {
        let rig = try await Rig()
        defer { rig.shutdown() }
        let workspace = Workspace(services: rig.services)
        let id = try await rig.host.open(in: rig.cwd, launchToken: "retry", name: nil, model: nil, thinking: nil)
        let sessionID = try #require(rig.bridge.session(id: id)).sessionID
        let prompt = "[[fail-once]] 跑一遍"
        workspace.send(prompt, to: AgentTarget(session: sessionID))
        try await eventually("出错") { try await rig.records(.live).first?.state == .known(.error) }
        let failed = try #require(try await rig.records(.live).first)
        #expect(failed.canRetry)
        try await eventually("对话里只有你的话") { try await rig.store.piMessages(of: sessionID).map(\.text) == [prompt] }

        workspace.retry(failed)

        try await eventually("重跑做完") { try await rig.store.piMessages(of: sessionID).map(\.text) == [prompt, "ECHO \(prompt) IMAGES[]"] }
        try await eventually("歇下") { try await rig.records(.live).first?.state == .known(.settled) }
        #expect(try RawDB(rig.services.location.databaseURL).count("sendRecords") == 1)
    }
}
#endif
