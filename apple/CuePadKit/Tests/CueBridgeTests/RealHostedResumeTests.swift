#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CueBridge

@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedResumeTests {
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
            try await rig.bridge.send(SessionMessage(text: "PING-TWO"), to: a)
            try await rig.replied("PING-TWO", in: first)
        }
    }

    @Test(.tags(.smoke), arguments: Hosting.allCases)
    func anEndedSessionIsResumedByANewProcessWithItsConversation(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: noDeadline) { rig in
            rig.model.on("Which word?") { request in
                .say(request.said.lazy.compactMap { $0.firstMatch(of: /Remember the word (\w+)/)?.1 }.first.map(String.init) ?? "UNKNOWN")
            }
            let id = try await rig.open()
            let first = try await rig.converse("Remember the word PAPAYA.", in: id)
            try await eventually("第一轮答完") { rig.bridge.session(id: id)?.state == .settled }
            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }
            _ = try await rig.restartRuntime()

            let resumed = try await rig.runtime.resume(rig.indexed(first))
            let back = try #require(rig.bridge.session(id: resumed))
            #expect(back.sessionID == first.sessionID && back.pid != first.pid)
            switch hosting {
            case .grok: #expect(rig.runsPinned(back.pid))
            case .dsh: #expect(commandLine(of: back.pid).contains("/\(PinnedAgent.dsh.name)/\(PinnedAgent.dsh.version)/"), "\(commandLine(of: back.pid))")
            case .claude, .codex: break
            }
            try await rig.bridge.send(SessionMessage(text: "Which word?"), to: resumed)
            try await eventually("答出先前记下的词") { rig.lastReply(first) == "PAPAYA" }
            let request = try #require(rig.model.requests.last { !$0.tools.isEmpty && $0.prompt.contains("Which word?") })
            let said = request.said
            if hosting == .codex {
                #expect(said.suffix(2) == ["Remember the word PAPAYA.", "Which word?"], "恢复后模型看到先前的对话：\(said)")
            } else {
                // 各家给你的话包了一层（Grok 的 `<user_query>`、dsh 的运行环境、Claude Code 插进的提醒）
                let earlier = said.lastIndex { $0.contains("Remember the word PAPAYA.") }
                #expect(said.last?.contains("Which word?") == true && earlier.map { $0 < said.count - 1 } == true, "恢复后模型看到先前的对话：\(said)")
            }
        }
    }

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
            try await rig.bridge.send(SessionMessage(text: "PING-TWO"), to: kept)
            try await rig.replied("PING-TWO", in: first)
        }
    }

    @Test(arguments: [(Hosting.codex, "waiting"), (.claude, "launching"), (.codex, "launching"), (.grok, "launching")])
    func quittingTheAppDuringAResumeLeavesNoProcess(_ hosting: Hosting, _ phase: String) async throws {
        try await EndRig.run(hosting, timing: noDeadline) { rig in
            let first: Session
            if phase == "waiting" {
                first = try await quitWhileSlow(rig)
            } else {
                let id = try await rig.open()
                first = try await rig.converse("PING-ONE", in: id)
                try await rig.idleOut(id)
                try await eventually("闲置到点、旧进程走了") { rig.bridge.session(id: id) == nil && kill(first.pid, 0) != 0 }
            }
            let resuming = Task { try await rig.connect(rig.indexed(first)) }
            if phase == "waiting" { try await Task.sleep(for: .milliseconds(200)) } else { try await eventually("起了新进程") { rig.launched.count == 2 } }
            await rig.runtime.stop()()
            _ = await resuming.result
            #expect(rig.launched.filter { kill($0, 0) == 0 }.isEmpty, "App 退出后还有进程：\(rig.launched.filter { kill($0, 0) == 0 })")
        }
    }

    private func quitWhileSlow(_ rig: EndRig) async throws -> Session {
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
