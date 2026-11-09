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

    /// 看变化记录，不看此刻的状态：一轮可能在开始等之前就做完了；按歇下的时刻认，之前停下的那一轮不算。发话之前取 `start`。
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

    /// 同 `eventually`，等不到时带上会话与终端画面（终端里按键后的事看画面才分得清是谁没动）。
    func waitOnScreen(_ what: String, on terminal: ClaudeTerminal, in id: PiSession.ID, _ condition: () async throws -> Bool) async throws {
        do {
            try await eventually(what, condition)
        } catch {
            throw Stuck(description: "等不到：\(what)；会话：\(String(describing: bridge.session(id: id)?.state)) \(String(describing: bridge.session(id: id)?.detail)) \(String(describing: bridge.session(id: id)?.question))；终端：\n\(await terminal.screen)")
        }
    }

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
        let turn = try #require(session()?.turnStartedAt), answered = try #require(try transcript(session()?.sessionFile).recap.answeredAt)
        #expect(turn <= answered, "\(turn) \(answered)")
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
