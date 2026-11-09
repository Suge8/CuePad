#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 一轮结束时同一进程上还有认不出主人的子线程：先一起再问、认清了再歇下（`CodexRuntime.endTurn`）。
/// 子线程的 `thread/read` 读不到、挂住、被取消由中转（`CodexReadFault`）排定，其余是真 Codex 与假模型。
extension RealCodexHostedTests {
    /// 主会话派出 `children`（每个一个子代理，名字就是任务名），派完停在 `parent` 闸门上，放行后照 `then` 答；子代理答完时补的一轮答 BANANA。
    /// 子代理的请求由 `child` 定。返回时每个子线程的第一条推送都已读不到（中转的模式要是 `fail`）。
    private func dispatch(
        _ rig: CodexRig, _ children: [String], parent: FakeGate, then: FakeReply = .say("DISPATCHED"),
        child: @escaping @Sendable (FakeRequest) -> FakeReply
    ) async throws -> PiSession.ID {
        let fault = try #require(rig.readFault)
        let prompt = "Spawn subagents: \(children.joined(separator: ", "))."
        rig.model.on("Child task: ", reply: child)
        rig.model.on({ $0.prompt.contains(prompt) }) { request in
            let step = request.messages.filter { !$0.calls.isEmpty }.count
            return step < children.count
                ? .call("spawn_agent", ["task_name": children[step], "message": "Child task: \(children[step]).", "fork_turns": "none"])
                : .held(parent, then: then)
        }
        rig.model.on({ $0.said.contains { $0.contains(prompt) } && $0.messages.contains { $0.text.contains("BANANA") } }) { _ in .say("BANANA") }
        let id = try await open(rig, "token-settle")
        try await rig.bridge.send(PiMessage(text: prompt), to: id)
        try await parent.reached()
        try await eventually("子线程的第一条推送都读不到") { fault.threads("fail").count == children.count }
        return id
    }

    private func owner(_ rig: CodexRig, _ id: PiSession.ID, thread: String) -> CodexRuntime.Owner? {
        rig.runtime.threads["\(thread).\(rig.runtime.tracked[id]?.pid ?? 0)"]
    }

    /// 再问时仍读不到：先歇下，它不算别人的线程。它的下一条推送来时再问、认出：进名册、等子代理；做完补一轮取结果。
    @Test func aChildStillUnreadableWhenTheTurnEndsIsListedOnItsNextPush() async throws {
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail) { rig in
            let parent = rig.model.gate(), working = rig.model.gate(), finishing = rig.model.gate()
            let id = try await dispatch(rig, ["apple"], parent: parent) { request in
                request.step == 0
                    ? .held(working, then: .custom("exec", #"const r = await tools.exec_command({"cmd": "echo hi"}); text(JSON.stringify(r));"#))
                    : .held(finishing, then: .say("BANANA"))
            }
            parent.open()
            try await eventually("再问仍读不到，歇下") { rig.bridge.session(id: id)?.state == .settled }

            rig.readFault?.mode = .pass
            working.open()
            try await eventually("它跑命令的推送认出了它") {
                rig.bridge.session(id: id).map { $0.state == .delegating && $0.subagents.map(\.name) == ["apple"] } == true
            }
            finishing.open()
            try await eventually("做完补一轮取结果") {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last == "BANANA" } == true
            }
        }
    }

    /// 再问时用户又说了一句、新一轮开始：被取消的再问不算读不到，这一轮结束时再问认出、在等子代理。
    @Test func aNewTurnDuringTheReaskLeavesTheChildToTheNextAsk() async throws {
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail) { rig in
            rig.model.on("Reply with the single word KIWI", .say("KIWI"))
            let parent = rig.model.gate()
            let id = try await dispatch(rig, ["apple"], parent: parent) { _ in .hang }
            let fault = try #require(rig.readFault)
            let child = try #require(fault.threads("fail").first)
            fault.mode = .hold
            parent.open()
            try await eventually("歇下前的再问挂住") { fault.threads("hold") == [child] }
            #expect(rig.bridge.session(id: id)?.state == .thinking)

            try await rig.bridge.send(PiMessage(text: "Reply with the single word KIWI."), to: id)
            try await eventually("新一轮开始，再问收场") {
                if case .asking = owner(rig, id, thread: child) { return false }
                return rig.runtime.tracked[id]?.ending == nil
            }
            fault.mode = .pass
            let log = ChangeLog(rig.bridge)
            try await eventually("这一轮答完在等子代理") {
                rig.bridge.session(id: id).map {
                    $0.state == .delegating && $0.subagents.map(\.name) == ["apple"] && rig.replies($0).last == "KIWI"
                } == true
            }
            #expect(log.settles == 0, "\(log.states)")
        }
    }

    /// 再问一起发出，整体至多 `AgentTimeouts.settleAsk`（按注入的钟）：读一直不回时卡片不会久停在“在跑”，没回的等下一次再问。
    @Test func theReaskIsConcurrentAndBounded() async throws {
        let clock = ManualTiming()
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail, timing: clock.timing) { rig in
            let parent = rig.model.gate()
            let id = try await dispatch(rig, ["apple", "pear"], parent: parent) { _ in .hang }
            let fault = try #require(rig.readFault)
            fault.mode = .hold
            parent.open()
            try await eventually("两个一起再问") { fault.threads("hold").count == 2 }
            #expect(rig.bridge.session(id: id)?.state == .thinking)
            await clock.waitForSleeper(until: clock.now.addingTimeInterval(AgentTimeouts.settleAsk.seconds))
            clock.advance(AgentTimeouts.settleAsk)
            try await eventually("到点歇下") { rig.bridge.session(id: id)?.state == .settled }
        }
    }

    enum Gone: CaseIterable { case processExits, runtimeStops }

    /// 推迟歇下时会话没了（进程退出、CuePad 停下接入）：推迟的歇下跟着取消，进程退出清掉的线程表不会被写回。
    @Test(arguments: Gone.allCases) func theDeferralEndsWithTheSession(_ gone: Gone) async throws {
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail) { rig in
            let parent = rig.model.gate()
            let id = try await dispatch(rig, ["apple", "pear"], parent: parent) { _ in .hang }
            let fault = try #require(rig.readFault)
            fault.mode = .hold
            parent.open()
            try await eventually("歇下前的再问挂住") { !fault.threads("hold").isEmpty }
            let ending = try #require(rig.runtime.tracked[id]?.ending)
            let pid = try #require(rig.bridge.session(id: id)?.pid)
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
}
#endif
