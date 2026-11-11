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

    /// 发话停下这一轮时它还没开跑（-32600），在等它开跑好补停时被停止取消：停止接手同一次停下，这一轮照样结束，下一句开出新一轮。
    @Test func aStopTakingOverAMessageWaitingForTheTurnToStartStillStopsIt() async throws {
        try await withCodexRig(readFault: .pass) { rig in
            let fault = try #require(rig.readFault)
            let first = rig.model.gate()
            rig.model.on("Take your time", .held(first, then: .say("TOO LATE")))
            rig.model.on("Reply with the single word NEXT", .say("NEXT"))
            let id = try await open(rig, "token-late-start")
            fault.lateStart = true
            try await rig.bridge.send(SessionMessage(text: "Take your time."), to: id)
            try await first.reached()

            let speech = Task { try await rig.bridge.send(SessionMessage(text: "Reply with the single word LOST."), to: id) }
            try await eventually("发话的停止回了 -32600，在等这一轮开跑") { fault.refusedStops == 1 }
            async let stop: Void = rig.bridge.abort(id)
            await #expect(throws: CancellationError.self) { try await speech.value }
            fault.lateStart = false
            try await stop
            #expect(fault.refusedStops == 1)
            #expect(rig.bridge.session(id: id)?.state == .settled)

            let stopped = Date()
            try await rig.bridge.send(SessionMessage(text: "Reply with the single word NEXT."), to: id)
            let session = try #require(rig.bridge.session(id: id))
            try await eventually("下一句开出新一轮、答完") { rig.bridge.session(id: id)?.state == .settled && rig.replies(session).last == "NEXT" }
            #expect(try #require(rig.bridge.session(id: id)?.turnStartedAt) > stopped)
            #expect(!rig.replies(session).contains("TOO LATE"))
        }
    }
}
#endif
