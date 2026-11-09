#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealBrainTests {
    /// 大脑关了 Grok 的钩子，这段时序录不出来：录像带照 1.0.70 带停止钩子实测的事件先后整理（头一段是 aMessageGetsAReplyContextAndAFinishedTurn 录下的起大脑），只回放。
    @Test(.enabled(if: RealAgents.mode(of: .grok) == .replay, "录像带是整理出来的，只回放"))
    func interjectionsStrandedAfterTheLastRequestAreReceivedByTheTurnsGrokOpensForThem() async throws {
        AgentTape.use(.grok)
        try await withRig(.grok) { rig in
        let first = UUID(), second = UUID(), third = UUID()
        try await rig.brain.send("Reply with only the single word ALPHA.", images: [], id: first)
        try await eventually("第一句的回答") { rig.events.contains { if case .speaking(let d?) = $0 { d.text == "ALPHA" } else { false } } }
        try await rig.brain.send("Reply with only the single word BETA.", images: [], id: second)
        try await rig.brain.send("Reply with only the single word GAMMA.", images: [], id: third)
        try await rig.finished(3)

        #expect(rig.failures == [], "\(rig.events)")
        let turns = rig.turns.map { ($0.received, $0.reply ?? "") }
        #expect(turns.map(\.0) == [[first], [second], [third]], "\(rig.events)")
        #expect(turns.map(\.1) == ["ALPHA", "BETA", "GAMMA"], "\(rig.events)")
        }
    }
}
#endif
