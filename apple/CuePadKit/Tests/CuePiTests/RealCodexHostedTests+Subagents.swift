#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealCodexHostedTests {
    // MARK: 子代理（gpt-6-luna 一档的 `collaboration` 工具：spawn_agent、wait_agent）

    @Test func aSubagentShowsUpInTheRoster() async throws {
        try await withCodexRig(model: "gpt-6-luna") { rig in
            // 假模型答得太快：派活的下一步等 CuePad 认出子代理再放行，否则这一轮会先歇下、再进“等子代理”（真模型要几秒；负载高时实测会错开）
            let known = rig.model.gate()
            // 子代理先答完时，主会话下一步的末条消息是子代理的 FINAL_ANSWER 通知：认整段对话里的那句话，不认末条
            // 步数也数整段对话里的工具调用：FINAL_ANSWER 通知算新的一句话，`step` 会从 0 重数
            rig.model.on({ $0.said.contains { $0.contains("Spawn one subagent called pong") } }) { request in
                switch request.messages.filter({ !$0.calls.isEmpty }).count {
                case 0: .call("spawn_agent", ["task_name": "pong", "message": "Child task: pong. Reply with PONG.", "fork_turns": "none"])
                case 1: .held(known, then: .call("wait_agent", ["timeout_ms": 30000]))
                default: .say("The subagent said PONG")
                }
            }
            rig.model.on("Child task: pong") { _ in .say("PONG") }
            let id = try await open(rig, "token-3")
            let log = ChangeLog(rig.bridge)

            try await rig.bridge.send(PiMessage(text: "Spawn one subagent called pong and tell me what it said."), to: id)
            try await known.reached()
            try await eventually("认出了子代理") { rig.bridge.session(id: id)?.subagents.map(\.name) == ["pong"] }
            known.open()

            // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次变化
            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && log.states.contains(.thinking) && log.states.last == .settled }
            #expect(log.settles == 1, "\(log.states)")
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["pong"])
            #expect(roster.first?.phase == .known(.done) && roster.first?.settledAt != nil)
            #expect(roster.first?.action.contains("PONG") == true)

            // 子代理自己的会话文件与主会话同层，会话索引里只有主会话
            let main = try #require(rig.bridge.session(id: id)?.sessionID)
            let files = try #require(FileManager.default.enumerator(at: rig.codex.home.appending(path: "sessions"), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            #expect(files.count == 2)
            let history = HistoryEventLog(PiHistoryIndexer(agent: .codex, paths: rig.codex.paths, files: scratchFiles) { _ in nil }!)
            try await eventually("回填完") { history.finishedBackfill }
            // 主会话文件在这一轮歇下后可能还在写，会多一次更新：只看更新了哪些会话
            #expect(Set(history.updates.map(\.checkpoint.sessionID)) == [main])
            let indexed = history.events.compactMap { if case .backfillFinished(let files?) = $0 { files } else { nil } }.first
            #expect(indexed?.map(\.lastPathComponent).allSatisfy { $0.contains(main) } == true && indexed?.count == 1)
        }
    }

    /// 子代理的请求停在闸门上，代替原来让它 sleep：主会话先答 DISPATCHED 歇在“等子代理”，放行后读回结果才歇下。
    /// 假模型派完活立刻答完（真模型要几秒），这一轮结束时 CuePad 可能还没认出子代理：要先认清再歇下，不先报一次歇下。
    /// `childUnreadableWhileParentRuns`：这一轮结束前子线程的 `thread/read` 都读不到（`CodexReadFault`）。
    @Test(arguments: [false, true]) func aSubagentLeftRunningIsReadBackBeforeSettling(childUnreadableWhileParentRuns: Bool) async throws {
        try await withCodexRig(model: "gpt-6-luna", readFault: childUnreadableWhileParentRuns ? .whileParentRuns : nil) { rig in
            let gate = rig.model.gate()
            rig.model.on("Spawn one subagent called fruit") { request in
                request.step == 0
                    ? .call("spawn_agent", ["task_name": "fruit", "message": "Child task: fruit. Reply with BANANA.", "fork_turns": "none"])
                    : .say("DISPATCHED")
            }
            rig.model.on({ $0.said.contains { $0.contains("Spawn one subagent called fruit") } && $0.messages.contains { $0.text.contains("BANANA") } }) { _ in .say("BANANA") }
            rig.model.on("Child task: fruit", .held(gate, then: .say("BANANA")))
            let id = try await open(rig, "token-wake")
            let log = ChangeLog(rig.bridge)

            try await rig.bridge.send(PiMessage(text: "Spawn one subagent called fruit and do not wait for it."), to: id)

            try await gate.reached()
            // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次变化
            try await eventually("这一轮结束、在等子代理") { rig.bridge.session(id: id)?.state == .delegating && log.states.last == .delegating }
            #expect(log.settles == 0, "\(log.states)")
            #expect(rig.bridge.session(id: id)?.subagents.map(\.name) == ["fruit"])
            let delegating = try #require(rig.bridge.session(id: id))
            let dispatched = try #require(try rig.transcript(delegating).recap.answeredAt)

            gate.open()
            try await eventually("读到结果后歇下") {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last == "BANANA" } == true && log.states.last == .settled
            }
            #expect(log.settles == 1, "\(log.states)")
            // 歇下就绪（`PiSessionState.answered`）：派活那一轮的收尾早于补的那一轮的开始（CuePad 发出空输入的时刻），那一轮的收尾不早于它
            let settled = try #require(rig.bridge.session(id: id))
            let turn = try #require(settled.turnStartedAt), answered = try #require(try rig.transcript(settled).recap.answeredAt)
            #expect(dispatched < turn && turn <= answered, "\(dispatched) \(turn) \(answered)")
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["fruit"] && roster.first?.phase == .known(.done))
        }
    }
}
#endif
