#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// Codex 一轮结束时同一进程上还有认不出主人的子线程：先再问一遍、认清了再歇下（`CodexRuntime.endTurn`）。
/// 连的是照指令走的假 app-server（`ScriptedCodex`）：读不到、挂住、在哪一刻放行，真 Codex 排不出来。
@MainActor
@Suite
struct CodexSettlingTests {
    /// 再问时仍读不到：先歇下，但它不算别人的线程。它的下一条推送来时再问、认出，进名册、在等子代理；做完了补一轮去取结果。
    @Test func aChildStillUnreadableWhenTheTurnEndsIsListedOnItsNextPush() async throws {
        try await withScriptedCodex { rig in
            let (id, pid) = try await rig.openRunning()
            try await rig.childUnreadableThenHeld("c1", pid: pid)
            rig.parentCompleted()
            try await eventually("歇下前再问") { rig.reads("c1") >= 2 }
            rig.set("c1", read: "fail")
            rig.release("c1")
            try await eventually("歇下") { rig.state(id) == .settled }

            rig.set("c1", read: "ok")
            rig.childStarted("c1", turn: "ct2")
            try await eventually("认出、进名册、在等子代理") { rig.state(id) == .delegating && rig.roster(id) == ["fruit"] }
            rig.set("c1", turns: [ScriptedCodex.turn("completed")])
            rig.childCompleted("c1", turn: "ct2")
            try await eventually("子代理做完，补一轮取结果") { rig.turnStarts == 1 }
        }
    }

    /// 再问时用户又说了一句、新一轮开始：被取消的再问不算读不到，几个线程都等各自的下一条推送再问；这一轮结束时认出的都在等。
    @Test func aNewTurnDuringTheReaskLeavesEveryChildToItsNextPush() async throws {
        try await withScriptedCodex { rig in
            let (id, pid) = try await rig.openRunning()
            let log = ChangeLog(rig.bridge)
            for name in ["c1", "c2"] { try await rig.childUnreadableThenHeld(name, name: name, pid: pid) }
            rig.parentCompleted()
            try await eventually("歇下前再问") { rig.reads("c1") >= 2 || rig.reads("c2") >= 2 }
            rig.parentStarted("t2")
            try await eventually("新一轮开始，再问取消") { rig.runtime.tracked[id]?.ending == nil }
            try await eventually("都留作暂时读不到") { rig.owner("c1", pid) == "unreadable" && rig.owner("c2", pid) == "unreadable" }

            for name in ["c1", "c2"] {
                rig.set(name, read: "ok")
                rig.childStarted(name, turn: "ct2")
            }
            try await eventually("下一条推送认出") { Set(rig.roster(id)) == ["c1", "c2"] }
            rig.parentCompleted("t2")
            try await eventually("在等子代理") { rig.state(id) == .delegating && log.states.last == .delegating }
            #expect(log.settles == 0, "\(log.states)")
        }
    }

    /// 终端会话出错的一轮在推迟歇下时，又来同一轮的结束信号（常驻服务的 idle、钩子的 Stop，都不带原因）：卡片仍写出原因。
    @Test func aSecondEndSignalDuringTheDeferralKeepsTheReason() async throws {
        try await withScriptedCodex { rig in
            let (session, pid) = try await rig.attachTerminal()
            rig.runtime.startTurn(session, at: .now)
            rig.runtime.publish(session)
            try await rig.childUnreadableThenHeld("c1", pid: pid)
            rig.emit("error", ["threadId": "main", "willRetry": false, "error": ["message": "boom"]])
            rig.emit("thread/status/changed", ["threadId": "main", "status": ["type": "systemError"]])
            try await eventually("歇下前再问") { rig.reads("c1") >= 2 }
            rig.emit("thread/status/changed", ["threadId": "main", "status": ["type": "idle"]])
            rig.set("c1", read: "fail")
            rig.release("c1")
            try await eventually("歇下") { rig.state(session.id) != .thinking }
            #expect(rig.state(session.id) == .error)
            #expect(rig.bridge.session(id: session.id)?.errorMessage == "boom")
        }
    }

    /// 再问一起发出，整体至多 `AgentTimeouts.settleAsk`（按注入的钟）：读一直不回，主会话这一轮结束后卡片不会久停在“在跑”，到点没回的留作暂时读不到。
    @Test func theReaskIsConcurrentAndBounded() async throws {
        let clock = ManualTiming()
        try await withScriptedCodex(timing: clock.timing) { rig in
            let (id, pid) = try await rig.openRunning()
            for name in ["c1", "c2"] { try await rig.childUnreadableThenHeld(name, name: name, pid: pid) }
            rig.parentCompleted()
            try await eventually("两个一起再问") { rig.reads("c1") >= 2 && rig.reads("c2") >= 2 }
            #expect(rig.state(id) == .thinking)
            await clock.waitForSleeper()
            clock.advance(AgentTimeouts.settleAsk)
            try await eventually("到点歇下") { rig.state(id) == .settled }
            #expect(rig.owner("c1", pid) == "unreadable" && rig.owner("c2", pid) == "unreadable")
        }
    }

    enum Gone: CaseIterable { case processExits, runtimeStops }

    /// 推迟歇下时会话没了（进程退出、CuePad 停下接入）：推迟的任务跟着取消，进程退出清掉的线程表不会被它写回。
    @Test(arguments: Gone.allCases) func theDeferralEndsWithTheSession(_ gone: Gone) async throws {
        try await withScriptedCodex { rig in
            let (id, pid) = try await rig.openRunning()
            for name in ["c1", "c2", "c3"] { try await rig.childUnreadableThenHeld(name, name: name, pid: pid) }
            rig.parentCompleted()
            try await eventually("歇下前再问") { rig.reads("c1") + rig.reads("c2") + rig.reads("c3") >= 4 }
            let ending = try #require(rig.runtime.tracked[id]?.ending)
            switch gone {
            case .processExits:
                kill(pid, SIGKILL)
                try await eventually("会话撤走") { rig.bridge.session(id: id) == nil }
            case .runtimeStops:
                await rig.runtime.stop()()
            }
            #expect(ending.isCancelled)
            await ending.value
            guard gone == .processExits else { return }
            await quietPeriod(.milliseconds(300))
            #expect(rig.runtime.threads.keys.filter { $0.hasSuffix(".\(pid)") }.isEmpty, "\(rig.runtime.threads.keys.sorted())")
        }
    }

    /// 托管会话的提问（`item/tool/requestUserInput`）在这一轮结束时收起，推迟歇下期间也是：再答会被当成一句新话发出去。
    @Test func aQuestionIsPutAwayWhenTheTurnEnds() async throws {
        try await withScriptedCodex { rig in
            let (id, pid) = try await rig.openRunning()
            try await rig.childUnreadableThenHeld("c1", pid: pid)
            let question: [String: Any] = ["id": "q", "header": "", "question": "Pick one", "options": [["label": "A"], ["label": "B"]]]
            rig.emit("item/tool/requestUserInput", ["threadId": "main", "turnId": "t1", "itemId": "i", "questions": [question]], id: 900)
            try await eventually("等你回答") { rig.bridge.session(id: id)?.question?.isAnswerable == true }
            let prompt = try #require(rig.bridge.session(id: id)?.question?.promptID)
            rig.parentCompleted()
            try await eventually("歇下前再问") { rig.reads("c1") >= 2 }
            #expect(rig.bridge.session(id: id)?.question == nil)
            await #expect(throws: (any Error).self) { try await rig.bridge.answer(.option("A"), to: prompt, in: id) }
            #expect(rig.turnStarts == 0)
        }
    }
}
#endif
