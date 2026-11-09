#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealBrainTests {
    /// 最后一次请求结束之后、这一轮收尾之前插进的话，Grok 1.0.70 把它们搁浅，之后按先后各开一轮：每句由自己那一轮收下、各得到回答
    /// （本机 20/20 落在这个窗口，三轮各收一句）。第一句的回答停在闸门上，放行后等到 CuePad 收到这次请求的上下文用量（请求已结束）再插话，
    /// 第一句那一轮因此只收第一句。窗口的另一头定不住：Grok 读到 response.completed 就收尾，挡住连接、扣住它另发的起标题请求都不拖住这一轮
    /// （实测），机器忙时 BETA 到达前它已收尾，BETA 就开新的一轮、GAMMA 并进那一轮。两种先后都要守住的是：每句只收下一次、按先后，
    /// 收下它的那一轮照它回答。
    @Test(.enabled(if: RealAgents.runs(.grok), "没装 Grok"))
    func interjectionsStrandedAfterTheLastRequestAreReceivedByTheTurnsGrokOpensForThem() async throws {
        AgentTape.use(.grok)
        try await withRig(.grok) { rig in
        let model = try #require(rig.model), hang = model.gate()
        model.on({ $0.prompt.contains("single word ALPHA") }) { _ in .stream(["ALPHA"], until: hang) }
        let first = UUID(), second = UUID(), third = UUID()
        let words = [first: "ALPHA", second: "BETA", third: "GAMMA"]
        try await rig.brain.send("Reply with only the single word ALPHA.", images: [], id: first)
        try await hang.reached()
        hang.openForever()
        try await eventually("第一句的请求结束") { !rig.contexts.isEmpty }
        try await rig.brain.send("Reply with only the single word BETA.", images: [], id: second)
        try await rig.brain.send("Reply with only the single word GAMMA.", images: [], id: third)
        try await eventually("三句都收下、那几轮都做完") { rig.turns.flatMap(\.received).count == 3 && rig.count(.turnStarted) == rig.count(.turnFinished) }

        #expect(rig.failures == [], "\(rig.events)")
        let turns = rig.turns
        #expect(turns.flatMap(\.received) == [first, second, third], "\(rig.events)")
        #expect(turns.first?.received == [first] && turns.first?.reply == "ALPHA", "\(rig.events)")
        for turn in turns { #expect(turn.received.last.flatMap { words[$0] } == turn.reply, "\(rig.events)") }
        }
    }
}
#endif
