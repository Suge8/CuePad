#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

extension ClaudeTestbed {
    func waitForSession(pid: Int32) async throws -> PiSession {
        try await eventually("Claude Code 会话上桥") { session(pid: pid) != nil }
        return session(pid: pid)!
    }

    /// 看变化记录，不看此刻的状态：回放时一轮可能在开始等之前就做完了；按歇下的时刻认，之前停下的那一轮不算。发话之前取 `start`。
    func waitForTurn(_ id: PiSession.ID, since start: Date) async throws {
        func done() -> Bool {
            var worked = false
            for case .stateChanged(let session, _) in log.changes where session.id == id {
                if session.state.isWorking || session.state == .waitingForUser { worked = true }
                if worked && session.state == .settled && session.stateSince > start { return true }
            }
            return false
        }
        do {
            try await eventually("这一轮做完") { done() }
        } catch {
            throw Stuck(description: "等不到这一轮做完；会话：\(String(describing: bridge.session(id: id)?.state)) \(String(describing: bridge.session(id: id)?.detail)) \(String(describing: bridge.session(id: id)?.question))")
        }
    }

    func waitForQuestion(_ id: PiSession.ID, on terminal: ClaudeTerminal? = nil) async throws -> PiQuestion {
        do {
            try await eventually("会话在等你确认") { bridge.session(id: id)?.question?.promptID != nil }
        } catch {
            throw NoQuestion(description: "等不到会话在等你确认；会话：\(String(describing: bridge.session(id: id)))；终端：\n\(await terminal?.screen ?? "")")
        }
        return bridge.session(id: id)!.question!
    }

    /// 模型偶尔不照做（没调工具就答完了这一轮）：在同一会话里再说一次，只重来一次。
    func ask(_ prompt: String, on terminal: ClaudeTerminal, in id: PiSession.ID) async throws -> PiQuestion {
        for attempt in 0..<2 {
            try await terminal.type(prompt)
            var worked = false
            try await eventually("在等你确认或这一轮做完") {
                let session = bridge.session(id: id)
                if session?.state.isWorking == true { worked = true }
                return session?.question?.promptID != nil || (worked && session?.state == .settled)
            }
            if bridge.session(id: id)?.question?.promptID != nil || attempt == 1 { break }
        }
        return try await waitForQuestion(id, on: terminal)
    }

    static let backgroundWork = "Do two things in one message, then stop. (1) Launch one subagent with the Agent tool: subagent_type general-purpose, "
        + "run_in_background true, description ticker, prompt: Run the Bash command `for i in 1 2; do sleep 4; done; echo SUB_DONE` as one foreground "
        + "Bash call (not run_in_background), then reply SUB_DONE. (2) Run a Bash command with run_in_background true: `sleep 20; echo BG_DONE`. "
        + "After launching both, reply only with the word launched and end your turn. Do not wait or poll. "
        + "Whenever a background task reports back later, reply only with the word it printed."

    /// 子代理交回中途结果后，名下的后台命令做完时它以同一 id 再跑一次、再交回。
    static let earlyReport = "Launch one subagent with the Agent tool: subagent_type general-purpose, run_in_background true, description nested, "
        + "prompt: Run one Bash command with run_in_background true: `sleep 15; echo NESTED`. Then immediately reply with just WAITING and end your turn. "
        + "Do not wait, poll, sleep or use Monitor. When that command reports back later, reply only with NESTED_DONE. "
        + "After launching the subagent, reply only with the word launched and end your turn. Do not wait or poll. "
        + "Whenever the subagent reports back later, reply only with the last word it said."
    static let longSubagent = "Launch one subagent with the Agent tool: subagent_type general-purpose, run_in_background true, description victim, "
        + "prompt: Run the Bash command `for i in $(seq 1 12); do sleep 5; done; echo V` as one foreground Bash call (not run_in_background), then reply V. "
        + "After launching it, reply only with the word launched and end your turn. Do not wait or poll."
    static let stopSubagent = "Stop the background subagent now with the TaskStop tool, then reply only STOPPED."
    static let passThrough = #""$REAL" "$@""#
    static let backgroundSettings = #"{"permissions": {"allow": ["Bash", "TaskStop"]}}"#

    func expectSettledOnce(_ id: PiSession.ID, since start: Date, reply: String, roster: PiSubagentPhase, waits: Int = 1) async throws {
        let session = { [bridge] in bridge.session(id: id) }
        // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次歇下
        try await eventually("交回结果的那一轮做完") {
            session()?.state == .settled && (try? transcript(session()?.sessionFile))?.recap.lastReply?.contains(reply) == true
                && log.states.last == .settled
        }
        try await waitForDraftLanded(id)
        var states: [PiWorkState] = []
        for case .stateChanged(let changed, _) in log.changes where changed.id == id && changed.stateSince > start && changed.state != states.last {
            states.append(changed.state)
        }
        #expect(states.filter { $0 == .delegating }.count >= waits, "\(states)")
        #expect(states.filter { $0 == .settled } == [.settled] && states.last == .settled, "\(states)")
        #expect(states.dropLast().last?.isWorking == true && states.dropLast().last != .delegating, "歇下前是交回结果的那一轮：\(states)")
        #expect(session()?.subagents.map(\.phase) == [.known(roster)], "\(String(describing: session()?.subagents))")
        // 歇下就绪（`PiSessionState.answered`）：交回结果那一轮的收尾不早于它的开始（收到开它的 `task_notification` 的时刻）。
        // 只有连真 Agent 时可比：回放时 Mac 一侧的时刻随回放压缩，会话文件的时刻照录下的间隔
        if RealAgents.mode(of: .claudeCode) == .record {
            let turn = try #require(session()?.turnStartedAt), answered = try #require(try transcript(session()?.sessionFile).recap.answeredAt)
            #expect(turn <= answered, "\(turn) \(answered)")
        }
    }

    func transcript(_ file: URL?) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(file), agent: .claudeCode, from: nil, files: files)
    }

    func index(_ file: URL?) async throws {
        let update = try transcript(file)
        let session = IndexedSession(
            id: try #require(update.checkpoint.sessionID), path: update.file.path, cwd: work.path, lastActivityAt: .now, agent: .claudeCode)
        try await store.upsertPiSessions([PiSessionUpsert(session: session, checkpoint: try JSONEncoder().encode(update.checkpoint), transcript: nil)], host: "mac")
    }

    /// 回答写进会话文件可能晚于这一轮歇下，等它落盘。
    func waitForDraftLanded(_ id: PiSession.ID) async throws {
        let file = bridge.session(id: id)?.sessionFile
        var newest: Date?
        try await eventually("回答落盘") {
            newest = (try? transcript(file))?.messages.last { $0.role == .known(.pi) }?.at
            return newest.map { $0 >= start(of: id) } ?? false
        }
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return }
        #expect(draft.landed(newestReply: newest), "正在说的话起点 \(draft.since.timeIntervalSince1970)，最近一条回答 \(String(describing: newest?.timeIntervalSince1970))")
    }

    private func start(of id: PiSession.ID) -> Date {
        log.changes.compactMap { if case .stateChanged(let session, _) = $0, session.id == id, session.state.isWorking { session.stateSince } else { nil } }
            .last ?? .distantPast
    }
}
#endif
