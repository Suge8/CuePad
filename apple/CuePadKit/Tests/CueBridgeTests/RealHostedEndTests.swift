#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import OSLog
import Testing
@testable import CueBridge

/// 托管会话收尾的同一条规则，每家一样（`HostedProcesses`）：
/// 忙时点结束先停下这一轮（Agent 自己把被中断的这一轮写进会话记录），再关输入、有宽限地收进程，结束报成功；
/// 请它退出（结束、闲置到点、让出）的那一刻就下桥，之后的话走恢复，恢复等旧进程收完再起，同一会话同一时刻只有一个进程；
/// 旧进程不肯退也只等到 SIGKILL 为止。
/// 各家各走一遍的只有各家自己接的那部分（停这一轮、接着会话、起进程时登记）；收尾的时限、升级与日志全在 `HostedProcesses`，
/// 由一家（Codex）作代表。每个用例自己一套钟与临时目录，可以并行。
@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedEndTests {
    /// 一个 Agent 进程上接着验各家停这一轮的接法，收尾用真钟：
    /// 起来马上点结束（没有在跑的一轮，不发中断）；说出一句马上点停止（#81：不等它开跑，Claude Code 不等 init、Codex 不丢在开跑前的停止）；
    /// 再说一句、这一轮在跑时点结束：先停下这一轮（Agent 自己把它写进会话记录）再收进程。都不等满 `AgentTimeouts.stop`。
    /// "说出一句马上点结束"不另跑：结束经 `HostedProcesses.retire` 调的就是上面停止走的 `abort`，收尾在忙时结束里验。
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
            // 前面停过一轮，会话记录里已有一条"已停止"：要的是第二句之后的那条
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

    /// 被请退出后进程不走（不理 SIGTERM、一直握着输出）：宽限后 SIGTERM、再宽限后 SIGKILL（按 runtime 的钟，这里拨）；
    /// 恢复等到这次收尾就起新进程，旧进程在新进程起来之前已经不在。升级与等旧进程都在共用层，一家作代表；
    /// 各家的恢复都走等旧进程这一步，见 `RealHostedResumeTests` 的第一例。
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

    /// 停这一轮没成（Agent 被冻住、不回）：结束照样当场报成功、下桥，到点照样收进程，失败原因记进日志（不报给用户）。
    /// 时限、日志与收进程都在 `HostedProcesses.retire`，一家作代表；各家经它停这一轮见第一例。
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

/// 本进程里 `HostedProcesses` 记下的日志
private func hostedLog(since: Date) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    return try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "subsystem == %@ AND category == 'hosted'", AppIdentity.id))
        .map(\.composedMessage)
}
#endif
