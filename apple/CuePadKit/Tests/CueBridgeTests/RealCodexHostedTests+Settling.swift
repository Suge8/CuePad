#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

extension RealCodexHostedTests {
    private func dispatch(
        _ rig: CodexRig, _ children: [String], parent: FakeGate, then: FakeReply = .say("DISPATCHED"),
        child: @escaping @Sendable (FakeRequest) -> FakeReply
    ) async throws -> Session.ID {
        let fault = try #require(rig.readFault)
        let prompt = "Spawn subagents: \(children.joined(separator: ", "))."
        rig.model.on("Child task: ", reply: child)
        rig.model.on({ $0.prompt.contains(prompt) }) { request in
            let step = request.messages.filter { !$0.calls.isEmpty }.count
            return step < children.count
                ? .call("spawn_agent", ["task_name": children[step], "message": "Child task: \(children[step]).", "fork_turns": "none"])
                : parent.held == 0 ? .held(parent, then: then) : then
        }
        rig.model.on({ $0.said.contains { $0.contains(prompt) } && $0.messages.contains { $0.text.contains("BANANA") } }) { _ in .say("BANANA") }
        let id = try await open(rig, "token-settle")
        try await rig.bridge.send(SessionMessage(text: prompt), to: id)
        try await parent.reached()
        try await eventually("子线程的第一条推送都读不到") { fault.threads("fail").count == children.count }
        return id
    }

    private func owner(_ rig: CodexRig, _ id: Session.ID, thread: String) -> CodexRuntime.Owner? {
        rig.runtime.tracked[id]?.threads[thread]
    }

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
            let main = { (request: FakeRequest) in !request.isTitle && request.said.contains { $0.contains("Spawn subagents: apple.") } }
            let asked = rig.model.requests.filter(main).count
            finishing.open()
            // 只断言 CuePad 补开了一轮、请求发到了模型：那一轮里看不看得到子代理的结果取决于 Codex 先发子线程的 turn/completed、后把结果入队（#144），等 #144 做了再改回断言结果
            try await eventually("做完补一轮") {
                rig.model.requests.filter(main).count > asked && rig.bridge.session(id: id)?.state == .settled
            }
        }
    }

    @Test func aNewTurnDuringTheReaskLeavesTheChildToTheNextAsk() async throws {
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail) { rig in
            rig.model.on("Reply with the single word KIWI", .say("KIWI"))
            let parent = rig.model.gate()
            let id = try await dispatch(rig, ["apple"], parent: parent) { _ in .hang }
            let fault = try #require(rig.readFault)
            let child = try #require(fault.threads("fail").first)
            fault.mode = .hold
            parent.open()
            try await eventually("歇下前的再问挂住") { rig.runtime.tracked[id]?.ending != nil && fault.threads("hold") == [child] }
            #expect(rig.bridge.session(id: id)?.state == .thinking)

            try await rig.bridge.send(SessionMessage(text: "Reply with the single word KIWI."), to: id)
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

    @Test func theReaskIsConcurrentAndBounded() async throws {
        let clock = ManualTiming()
        try await withCodexRig(model: "gpt-6-luna", readFault: .fail, timing: clock.timing) { rig in
            let parent = rig.model.gate()
            let id = try await dispatch(rig, ["apple", "pear"], parent: parent) { _ in .hang }
            let fault = try #require(rig.readFault)
            fault.mode = .hold
            parent.open()
            try await eventually("两个一起再问") { rig.runtime.tracked[id]?.ending != nil && fault.threads("hold").count == 2 }
            #expect(rig.bridge.session(id: id)?.state == .thinking)
            try await clock.waitForSleeper(until: clock.now.addingTimeInterval(AgentTimeouts.settleAsk.seconds))
            clock.advance(AgentTimeouts.settleAsk)
            try await eventually("到点歇下") { rig.bridge.session(id: id)?.state == .settled }
        }
    }
}
#endif
