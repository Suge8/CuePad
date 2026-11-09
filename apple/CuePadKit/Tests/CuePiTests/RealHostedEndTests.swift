#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import OSLog
import Testing
@testable import CuePi

/// 托管会话收尾的同一条规则，每家一样（`HostedProcesses`）：
/// 忙时点结束先停下这一轮（Agent 自己把被中断的这一轮写进会话记录），再关输入、有宽限地收进程，结束报成功；
/// 请它退出（结束、闲置到点、让出）的那一刻就下桥，之后的话走恢复，恢复等旧进程收完再起，同一会话同一时刻只有一个进程；
/// 旧进程不肯退也只等到 SIGKILL 为止。
/// 一次只跑一个用例：每个都起真 Agent，全部一起起会把同一测试进程里别的用例挤过它们的时限（Pi 的 1 秒空闲、应答时限）。
@MainActor
@Suite(.serialized, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedEndTests {
    /// 收尾用真钟：宽限与升级照用户的样子走，停下这一轮之前就被 SIGTERM 收掉的话，会话记录里没有被停下的这一轮。
    @Test(arguments: Hosting.allCases)
    func endingABusySessionStopsTheTurnBeforeTheProcessQuits(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: .system) { rig in
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(PiMessage(text: "BUSY-HANG keep going"), to: id)
            try await eventually("这一轮在跑、停在模型里") { rig.asked("BUSY-HANG") && rig.bridge.session(id: id)?.state.isWorking == true }
            let session = try #require(rig.bridge.session(id: id))

            try await rig.bridge.end(id)
            #expect(rig.bridge.session(id: id) == nil)
            try await eventually("进程收掉") { kill(session.pid, 0) != 0 }
            let record = try rig.record(session)
            #expect(record.messages.contains { $0.role == .known(.user) && $0.text.contains("BUSY-HANG") })
            #expect(record.checkpoint.stoppedAt != nil, "会话记录里没有被停下的这一轮：\(record.messages.map(\.text))")
        }
    }

    /// 闲置到点被请退出；外壳在真 Agent 退出后还握着输出 3 秒（进程还没走）。请退出的那一刻就不在桥上，
    /// 紧接着的话（`MacExecutor` 的接法）接着同一会话、等旧进程走了才起新的，话送到。
    @Test(arguments: Hosting.allCases)
    func aMessageRightAfterTheSessionIsAskedToQuitResumesIt(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: noDeadline) { rig in
            try rig.mark("slow", true)
            let id = try await rig.open()
            try rig.mark("slow", false)
            let first = try await rig.converse("PING-ONE", in: id)

            try await rig.idleOut(id)
            try await eventually("闲置到点，请它退出了") { rig.has("eof.\(first.pid)") }
            #expect(rig.bridge.session(id: id) == nil, "请它退出了还在桥上")
            let resumed = try await rig.connect(rig.indexed(first))
            #expect(resumed != id)
            try await rig.bridge.send(PiMessage(text: "PING-TWO"), to: resumed)
            try await rig.replied("PING-TWO", in: first)
            #expect(rig.bridge.session(id: resumed)?.sessionID == first.sessionID)
            #expect(rig.overlaps.isEmpty, "同一会话同时有两个进程：\(rig.overlaps)")
            #expect(rig.launched.count == 2)
        }
    }

    /// 被请退出后进程不走（不理 SIGTERM、一直握着输出）：宽限后 SIGTERM、再宽限后 SIGKILL；恢复等到这次收尾就起新进程，
    /// 旧进程在新进程起来之前已经不在。宽限按起进程时给的钟量：Claude Code 是 runtime 的（这里拨），其余几家是真钟
    /// （它们的录像带录下的是真钟上的升级，换成 runtime 的不前进的钟，回放就等不到 SIGTERM）。
    @Test(arguments: Hosting.allCases)
    func aSessionWhoseProcessIgnoresSIGTERMIsResumedOnceItIsKilled(_ hosting: Hosting) async throws {
        let clock = ManualTiming()
        try await EndRig.run(hosting, timing: clock.timing) { rig in
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
            try await rig.bridge.send(PiMessage(text: "PING-TWO"), to: resumed)
            try await rig.replied("PING-TWO", in: first)
            #expect(rig.overlaps.isEmpty, "同一会话同时有两个进程：\(rig.overlaps)")
        }
    }

    /// 停这一轮没成（Agent 被冻住、不回）：结束照样当场报成功、下桥，到点照样收进程，失败原因记进日志（不报给用户）。
    @Test(arguments: Hosting.allCases)
    func aTurnThatCannotBeStoppedIsLoggedAndTheProcessIsStillCollected(_ hosting: Hosting) async throws {
        let clock = ManualTiming()
        try await EndRig.run(hosting, timing: clock.timing) { rig in
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(PiMessage(text: "BUSY-HANG keep going"), to: id)
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
