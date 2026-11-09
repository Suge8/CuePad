#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 取自真 Codex 0.162 会话文件的形状。
struct ConversationRuleTests {
    private func codexFile(_ events: [[String: Any]]) throws -> URL {
        let url = try makeTempDirectory().appending(path: "rollout.jsonl")
        var lines = [["timestamp": "2026-10-14T19:21:00.000Z", "type": "session_meta", "payload": ["id": "thread-1", "cwd": "/work"]] as [String: Any]]
        for (n, payload) in events.enumerated() {
            lines.append(["timestamp": String(format: "2026-10-14T19:21:%02d.000Z", n + 1), "type": "event_msg", "payload": payload])
        }
        try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func second(_ n: Int) -> Date { ISO8601DateFormatter().date(from: String(format: "2026-10-14T19:21:%02dZ", n))! }

    private func item(_ item: [String: Any]) -> [String: Any] { ["type": "item_completed", "item": item] }
    private func user(_ id: String, _ text: String) -> [String: Any] { item(["type": "UserMessage", "id": id, "content": [["type": "text", "text": text]]]) }
    private func agent(_ id: String, _ text: String, _ phase: String) -> [String: Any] {
        item(["type": "AgentMessage", "id": id, "content": [["type": "Text", "text": text]], "phase": phase])
    }

    @Test func aStoppedRoundKeepsWhatWasSaidAndAddsAStoppedLine() async throws {
        let fixture = try Fixture()
        var stopped = SessionFile(directory: try makeTempDirectory(), name: "stopped.jsonl")
        try stopped.append(
            SessionFile.header(id: "stopped"), SessionFile.user("u1", nil, "第一问", at: 1), SessionFile.assistant("a1", "u1", text: "第一答", at: 2),
            SessionFile.user("u2", "a1", "第二问", at: 3), SessionFile.assistant("a2", "u2", text: "说了半句", stop: "aborted", at: 4),
            SessionFile.user("u3", "a2", "<some_event>\n子任务完成\n</some_event>", at: 5), SessionFile.assistant("a3", "u3", text: "汇报", at: 6),
            SessionFile.user("u4", "a3", "第三问", at: 7), SessionFile.assistant("a4", "u4", text: nil, stop: "aborted", at: 8))

        let read = try PiHistory.index(file: stopped.url, from: nil)
        try await fixture.store.writePiTranscript(read.transcript)

        #expect(read.recap == PiRecap(lastPrompt: "第二问", lastReply: "汇报", pendingPrompt: nil, answeredAt: SessionFile.date(8)))
        #expect(try await fixture.store.piMessages(of: "stopped").map { "\($0.role.rawValue):\($0.text)" } == [
            "user:第一问", "pi:第一答", "user:第二问", "pi:说了半句", "system:已停止", "machine:<some_event>\n子任务完成\n</some_event>", "pi:汇报",
            "user:第三问", "system:已停止",
        ])

        let json = """
            [{"id":"u1","type":"user","text":"写个故事","time":{"created":1000000}},
             {"id":"a1","type":"assistant","error":{"type":"aborted"},"content":[{"type":"text","text":"从前有座山"}],"time":{"created":1000400,"completed":1006000}}]
            """
        var checkpoint = PiHistoryCheckpoint()
        var transcript = PiHistory.Transcript(fallbackID: "s", files: scratchFiles)
        for (seq, message) in try JSONDecoder().decode([OpenCodeMessage].self, from: Data(json.utf8)).enumerated() {
            try OpenCodeHistory.ingest(message, seq: Int64(seq), &checkpoint, &transcript)
        }
        #expect(transcript.messages.map { "\($0.role.rawValue):\($0.text)" } == ["user:写个故事", "pi:从前有座山", "system:已停止"])
    }

    @Test func aRoundEndedByADeclinedToolSaysDeclined() throws {
        let codex = try codexFile([
            ["type": "task_started"], user("u1", "建个文件"),
            item(["type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "touch x"], "status": "declined"]), ["type": "turn_aborted"],
        ])
        #expect(try PiHistory.index(file: codex, agent: .codex, from: nil, files: scratchFiles).messages.map(\.text) == ["建个文件", "已拒绝"])
    }

    @Test func theAnswerIsTimedFromYourMessageToWhenItWasDone() throws {
        let json = """
            [{"id":"u1","type":"user","text":"跑一下","time":{"created":1000000}},
             {"id":"a1","type":"assistant","finish":"stop","content":[{"type":"text","text":"跑完了"}],"time":{"created":1000400,"completed":1006000}}]
            """
        var checkpoint = PiHistoryCheckpoint()
        var transcript = PiHistory.Transcript(fallbackID: "s", files: scratchFiles)
        for (seq, message) in try JSONDecoder().decode([OpenCodeMessage].self, from: Data(json.utf8)).enumerated() {
            try OpenCodeHistory.ingest(message, seq: Int64(seq), &checkpoint, &transcript)
        }
        let answer = try #require(transcript.messages.last)
        let started = try #require(answer.roundStartedAt)
        #expect(answer.text == "跑完了" && answer.at.timeIntervalSince(started) == 6)
    }

    /// Codex 先报歇下（`Stop` 钩子）、钩子返回后才往会话文件写 `task_complete`。
    @Test func codexsFinalAnswerIsTheAnswerBeforeTheRoundIsMarkedComplete() throws {
        let file = try codexFile([["type": "task_started"], user("u1", "Reply with WRAPPED"), agent("m1", "WRAPPED", "final_answer")])

        let read = try PiHistory.index(file: file, agent: .codex, from: nil, files: scratchFiles)

        #expect(read.messages.map { "\($0.role.rawValue):\($0.text)" } == ["user:Reply with WRAPPED", "pi:WRAPPED"])
        #expect(read.recap == PiRecap(lastPrompt: "Reply with WRAPPED", lastReply: "WRAPPED", pendingPrompt: nil, answeredAt: second(3)))
    }

    @Test func aSteeredMessageInTheSameTurnGetsItsOwnAnswer() throws {
        let file = try codexFile([
            ["type": "task_started"], user("u1", "跑 sleep 20，跑完回 LONG-DONE"), agent("m1", "先跑命令。", "commentary"),
            user("u2", "顺便：6+6 等于几"), agent("m2", "12", "commentary"), agent("m3", "LONG-DONE", "final_answer"), ["type": "task_complete"],
        ])

        let read = try PiHistory.index(file: file, agent: .codex, from: nil, files: scratchFiles)

        #expect(read.messages.map { "\($0.role.rawValue):\($0.text)" } == [
            "user:跑 sleep 20，跑完回 LONG-DONE", "pi:先跑命令。", "user:顺便：6+6 等于几", "pi:LONG-DONE",
        ])
        #expect(read.recap == PiRecap(lastPrompt: "顺便：6+6 等于几", lastReply: "LONG-DONE", pendingPrompt: nil, answeredAt: second(7)))
    }
}
#endif
