#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 接着同一托管会话（`HostedProcesses.resume`）不论几个调用方、怎么交错，这个会话同一时刻至多一个进程，不留没人收的进程：
/// 同时来的恢复合成一次、拿到同一个 id；放弃的调用方各走各的；App 退出（`runtime.stop()`）之后不再起进程。
/// 合成、放弃与退出的判断都在共用层（`Resumptions`、`HostedProcesses`），一家（Codex）作代表；各家各走一遍的只有
/// 自己的恢复经不经共用层（第一例）与起进程时登记（App 退出在起进程时，Grok 与 dsh 同一套 `ACPHost.launch`，Grok 作代表）。
@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedResumeTests {
    /// 闲置到点被请退出、外壳在真 Agent 退出后还握着输出 3 秒（旧进程还没走）。请退出的那一刻就不在桥上；
    /// 紧接着同时来两条投送（`MacExecutor` 的接法）：接着同一会话、合成一次，等旧进程走了才起一个新的，话送到。
    @Test(arguments: Hosting.allCases)
    func twoResumesOfTheSameSessionAtOnceStartOneProcess(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: noDeadline) { rig in
            let first = try await quitWhileSlow(rig)
            async let one = rig.connect(rig.indexed(first))
            async let two = rig.connect(rig.indexed(first))
            let (a, b) = try await (one, two)
            #expect(a == b)
            #expect(rig.bridge.session(id: a)?.sessionID == first.sessionID)
            #expect(rig.launched.count == 2, "起了 \(rig.launched.count - 1) 个新进程")
            #expect(rig.overlaps.isEmpty, "同一会话同时有两个进程：\(rig.overlaps)")
            try await rig.bridge.send(PiMessage(text: "PING-TWO"), to: a)
            try await rig.replied("PING-TWO", in: first)
        }
    }

    /// 第一个恢复已经起了进程、还没连上，第二个到了：等它，不收它的进程。
    @Test func aResumeArrivingWhileAnotherIsLaunchingJoinsIt() async throws {
        try await EndRig.run(.codex, timing: noDeadline) { rig in
            let id = try await rig.open()
            let first = try await rig.converse("PING-ONE", in: id)
            try await rig.idleOut(id)
            try await eventually("闲置到点、旧进程走了") { rig.bridge.session(id: id) == nil && kill(first.pid, 0) != 0 }
            let one = Task { try await rig.connect(rig.indexed(first)) }
            try await eventually("第一个起了进程") { rig.launched.count == 2 }
            let two = Task { try await rig.connect(rig.indexed(first)) }
            let (a, b) = try await (one.value, two.value)
            #expect(a == b)
            #expect(rig.bridge.session(id: a) != nil, "拿回的会话不在桥上")
            #expect(rig.launched.count == 2, "起了 \(rig.launched.count - 1) 个新进程")
        }
    }

    /// 两个恢复在等旧进程，其中一个放弃（投送到了截止时刻）：它走它的，另一个照样接上，留下的进程就是桥上的那个。
    @Test func cancellingOneOfTwoResumesLeavesTheOtherConnected() async throws {
        try await EndRig.run(.codex, timing: noDeadline) { rig in
            let first = try await quitWhileSlow(rig)
            let one = Task { try await rig.connect(rig.indexed(first)) }
            let two = Task { try await rig.connect(rig.indexed(first)) }
            try await eventually("起了新进程") { rig.launched.count >= 2 }
            one.cancel()
            _ = await one.result
            let kept = try await two.value
            let session = try #require(rig.bridge.session(id: kept), "留下的那个恢复拿回的会话不在桥上")
            try await eventually("别的进程都收掉") { rig.launched.filter { kill($0, 0) == 0 } == [session.pid] }
            try await rig.bridge.send(PiMessage(text: "PING-TWO"), to: kept)
            try await rig.replied("PING-TWO", in: first)
        }
    }

    /// App 退出时恢复正在等旧进程收完（`waiting`），或已经起了新进程还没连上（`launching`）：退出之后一个进程都不剩。
    @Test(arguments: [(Hosting.codex, "waiting"), (.claude, "launching"), (.codex, "launching"), (.grok, "launching")])
    func quittingTheAppDuringAResumeLeavesNoProcess(_ hosting: Hosting, _ phase: String) async throws {
        try await EndRig.run(hosting, timing: noDeadline) { rig in
            let first: PiSession
            if phase == "waiting" {
                first = try await quitWhileSlow(rig)
            } else {
                let id = try await rig.open()
                first = try await rig.converse("PING-ONE", in: id)
                try await rig.idleOut(id)
                try await eventually("闲置到点、旧进程走了") { rig.bridge.session(id: id) == nil && kill(first.pid, 0) != 0 }
            }
            let resuming = Task { try await rig.connect(rig.indexed(first)) }
            // 等旧进程的那段有外壳多握的 3 秒，这里只是让恢复走进去
            if phase == "waiting" { try await Task.sleep(for: .milliseconds(200)) } else { try await eventually("起了新进程") { rig.launched.count == 2 } }
            await rig.runtime.stop()()
            _ = await resuming.result
            #expect(rig.launched.filter { kill($0, 0) == 0 }.isEmpty, "App 退出后还有进程：\(rig.launched.filter { kill($0, 0) == 0 })")
        }
    }

    /// 开一个会话说一句，闲置到点被请退出；外壳在真 Agent 退出后还握着 3 秒（旧进程还在），返回那时的会话。
    private func quitWhileSlow(_ rig: EndRig) async throws -> PiSession {
        try rig.mark("slow", true)
        let id = try await rig.open()
        try rig.mark("slow", false)
        let first = try await rig.converse("PING-ONE", in: id)
        try await rig.idleOut(id)
        try await eventually("闲置到点，请它退出了") { rig.has("eof.\(first.pid)") }
        try #require(rig.bridge.session(id: id) == nil, "请它退出了还在桥上")
        return first
    }
}
#endif
