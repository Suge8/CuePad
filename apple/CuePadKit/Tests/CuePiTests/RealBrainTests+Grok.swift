#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealBrainTests {
    /// 最后一次请求结束之后、这一轮收尾之前插进的话，Grok 1.0.70 把它们搁浅，之后按先后各开一轮：每句由自己那一轮收下、各得到回答。
    /// 第一句的回答停在闸门上，放行后等到 CuePad 收到这次请求的上下文用量（请求已结束）再插话，窗口因此是定的
    /// （实测 20/20 三轮各收一句；请求还没结束时插话则 20/20 并进同一轮，那是 `aMessageDuringATurnJoinsThatTurn` 的路径）。
    @Test(.enabled(if: RealAgents.runs(.grok), "没装 Grok"))
    func interjectionsStrandedAfterTheLastRequestAreReceivedByTheTurnsGrokOpensForThem() async throws {
        AgentTape.use(.grok)
        try await withRig(.grok) { rig in
        let model = try #require(rig.model), hang = model.gate()
        model.on({ $0.prompt.contains("single word ALPHA") }) { _ in .streamUntil(["ALPHA"], hang) }
        let first = UUID(), second = UUID(), third = UUID()
        try await rig.brain.send("Reply with only the single word ALPHA.", images: [], id: first)
        try await hang.reached()
        hang.openForever()
        try await eventually("第一句的请求结束") { !rig.contexts.isEmpty }
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
