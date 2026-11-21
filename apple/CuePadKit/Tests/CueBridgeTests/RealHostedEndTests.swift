#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import OSLog
import Testing
@testable import CueBridge

@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedEndTests {
    @Test(arguments: Hosting.allCases)
    func stoppingAndEndingStopTheTurnWithoutWaitingOutTheStopLimit(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: .system) { rig in
            rig.hang("BUSY-HANG")
            let idle = try await rig.open()
            let idlePid = try #require(rig.bridge.session(id: idle)).pid
            var began = ContinuousClock.now
            try await rig.bridge.end(idle)
            try await eventually("没说过话的进程收掉") { kill(idlePid, 0) != 0 }
            #expect(began.duration(to: .now) < .seconds(10), "起来马上结束用了 \(began.duration(to: .now))")

            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG first"), to: id)
            began = ContinuousClock.now
            try await rig.bridge.abort(id)
            try await eventually("停下了") { rig.bridge.session(id: id)?.state == .settled }
            #expect(began.duration(to: .now) < .seconds(10), "说出一句马上停止用了 \(began.duration(to: .now))")

            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG second"), to: id)
            try await eventually("这一轮在跑、停在模型里") { rig.asked("BUSY-HANG second") && rig.bridge.session(id: id)?.state.isWorking == true }
            let session = try #require(rig.bridge.session(id: id))
            began = ContinuousClock.now
            try await rig.bridge.end(id)
            #expect(rig.bridge.session(id: id) == nil)
            try await eventually("进程收掉") { kill(session.pid, 0) != 0 }
            #expect(began.duration(to: .now) < .seconds(10), "忙时结束用了 \(began.duration(to: .now))")
            let messages = try rig.record(session).messages
            let second = try #require(messages.lastIndex { $0.role == .known(.user) && $0.text.contains("BUSY-HANG second") })
            #expect(messages[second...].contains { $0.text == ChatNotice.stopped.rawValue }, "会话记录里没有被停下的这一轮：\(messages.map(\.text))")
        }
    }

    /// Codex 拒绝停开跑前的一轮（-32600），而这一轮的 `turn/started` 比拒绝先到：照样停下它，不再等一个已经来过的开跑。
    @Test func aCodexRefusalArrivingAfterTheTurnStartedStillStopsIt() async throws {
        try await EndRig.run(.codex, timing: .system) { rig in
            try #"""
            import sys
            held = None
            for line in sys.stdin:
                if held is None and "no active turn to interrupt" in line:
                    held = line
                    continue
                print(line, end="", flush=True)
                if held is not None and "turn/started" in line:
                    print(held, end="", flush=True)
                    held = None
            """#.write(to: rig.wrapper.appending(path: "late-refusal"), atomically: true, encoding: .utf8)
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG keep going"), to: id)
            let began = ContinuousClock.now
            try await rig.bridge.abort(id)
            try await eventually("停下了") { rig.bridge.session(id: id)?.state == .settled }
            let took = began.duration(to: .now)
            #expect(took < .seconds(10), "用了 \(took)")
        }
    }

    @Test func aSessionWhoseProcessIgnoresSIGTERMIsResumedOnceItIsKilled() async throws {
        let clock = ManualTiming()
        try await EndRig.run(.codex, timing: clock.timing) { rig in
            try rig.mark("stubborn", true)
            let id = try await rig.open()
            try rig.mark("stubborn", false)
            let first = try await rig.converse("PING-ONE", in: id)
            let old = first.pid

            try await rig.idleOut(id)
            try await eventually("闲置到点，请它退出了") { rig.has("eof.\(old)") }
            try #require(rig.bridge.session(id: id) == nil, "请它退出了还在桥上")
            let resuming = Task { try await rig.connect(rig.indexed(first)) }
            for _ in 0..<2 {
                let due = clock.now.addingTimeInterval(AgentTimeouts.endGrace.seconds)
                try await eventually("在等宽限") { kill(old, 0) != 0 || clock.hasSleeper(until: due) }
                clock.advance(AgentTimeouts.endGrace)
            }
            let resumed = try await resuming.value
            #expect(kill(old, 0) != 0, "旧进程还在")
            #expect(rig.bridge.session(id: resumed)?.pid != old)
            try await rig.bridge.send(SessionMessage(text: "PING-TWO"), to: resumed)
            try await rig.replied("PING-TWO", in: first)
            #expect(rig.overlaps.isEmpty, "同一会话同时有两个进程：\(rig.overlaps)")
        }
    }

    @Test func aTurnThatCannotBeStoppedIsLoggedAndTheProcessIsStillCollected() async throws {
        let clock = ManualTiming()
        try await EndRig.run(.codex, timing: clock.timing) { rig in
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG keep going"), to: id)
            try await eventually("这一轮在跑、停在模型里") { rig.asked("BUSY-HANG") && rig.bridge.session(id: id)?.state.isWorking == true }
            let session = try #require(rig.bridge.session(id: id))
            let since = Date()
            kill(session.pid, SIGSTOP)

            try await rig.bridge.end(id)
            #expect(rig.bridge.session(id: id) == nil)
            let due = clock.now.addingTimeInterval(AgentTimeouts.stop.seconds)
            try await eventually("在等这一轮停下") { clock.hasSleeper(until: due) }
            clock.advance(AgentTimeouts.stop)
            try await eventually("日志里记下没能停下这一轮") { try hostedLog(since: since).contains { $0.contains(session.sessionID) } }
            for _ in 0..<2 {
                let due = clock.now.addingTimeInterval(AgentTimeouts.endGrace.seconds)
                try await eventually("在等宽限") { kill(session.pid, 0) != 0 || clock.hasSleeper(until: due) }
                clock.advance(AgentTimeouts.endGrace)
            }
            try await eventually("进程照样收掉") { kill(session.pid, 0) != 0 }
        }
    }
}

private func hostedLog(since: Date) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    return try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "subsystem == %@ AND category == 'hosted'", AppIdentity.id))
        .map(\.composedMessage)
}
#endif
