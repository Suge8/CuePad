#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

extension RealCodexHostedTests {
    enum Restart: String, CaseIterable, Sendable { case speakWhileBusy, stopThenSpeak }

    /// 停下这一轮紧接着发话（发话自己停、先停再发）：新一轮从停下之后算起，Cue 认的是新一轮的凭据，被停下那一轮的拒收。
    @Test(arguments: Restart.allCases) func aMessageRightAfterStoppingStartsANewTurn(_ restart: Restart) async throws {
        try await withCodexRig { rig in
            let first = rig.model.gate(), second = rig.model.gate()
            rig.model.on("Take your time", .held(first, then: .say("TOO LATE")))
            rig.model.on("Reply with the single word NEXT", .held(second, then: .say("NEXT")))
            rig.model.on("Reply with the single word CUE", .say("CUE"))
            let id = try await open(rig, "token-restart")
            try await rig.bridge.send(SessionMessage(text: "Take your time."), to: id)
            try await first.reached()
            let old = try #require(rig.bridge.session(id: id)?.turnStartedAt)

            if restart == .stopThenSpeak { try await rig.bridge.abort(id) }
            let stopped = Date()
            try await rig.bridge.send(SessionMessage(text: "Reply with the single word NEXT."), to: id)
            try await second.reached()
            let session = try #require(rig.bridge.session(id: id))
            let current = try #require(session.turnStartedAt)
            #expect(current > stopped, "新一轮的开始 \(current) 应晚于停下 \(stopped)，被停下那一轮 \(old)")
            #expect(session.state.hasPendingWork)

            let cue = { (turn: Date) in SessionMessage(text: "Reply with the single word CUE.", policy: .cue(deliveryID: "cue-delivery", turnStartedAt: turn)) }
            await #expect(throws: BridgeError.rejected("user_turn")) { try await rig.bridge.send(cue(old), to: id) }
            try await rig.bridge.send(cue(current), to: id)
            try await eventually("Cue 用新一轮的凭据接管、答完") {
                rig.bridge.session(id: id)?.state == .settled && rig.replies(session).last == "CUE"
            }
            #expect(!rig.replies(session).contains("TOO LATE"))
        }
    }
}
#endif
