#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CueBridge

extension ClaudeTestbed {
    func waitForTurn(_ id: Session.ID, since start: Date) async throws {
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

    func waitForQuestion(_ id: Session.ID) async throws -> Question {
        do {
            try await eventually("会话在等你确认") { bridge.session(id: id)?.question?.promptID != nil }
        } catch {
            throw NoQuestion(description: "等不到会话在等你确认；会话：\(String(describing: bridge.session(id: id)))")
        }
        return bridge.session(id: id)!.question!
    }

    static let passThrough = #""$REAL" "$@""#
    static let backgroundSettings = #"{"permissions": {"allow": ["Bash", "TaskStop"]}}"#

    func expectSettledOnce(_ id: Session.ID, since start: Date, reply: String, roster: SubagentPhase, waits: Int = 1) async throws {
        let session = { [bridge] in bridge.session(id: id) }
        try await eventually("交回结果的那一轮做完") {
            session()?.state == .settled && (try? transcript(session()?.sessionFile))?.recap.lastReply?.contains(reply) == true
                && log.states.last == .settled
        }
        try await waitForDraftLanded(id)
        var states: [WorkState] = []
        for case .stateChanged(let changed, _) in log.changes where changed.id == id && changed.stateSince > start && changed.state != states.last {
            states.append(changed.state)
        }
        #expect(states.filter { $0 == .delegating }.count >= waits, "\(states)")
        #expect(states.filter { $0 == .settled } == [.settled] && states.last == .settled, "\(states)")
        #expect(states.dropLast().last?.isWorking == true && states.dropLast().last != .delegating, "歇下前是交回结果的那一轮：\(states)")
        #expect(session()?.subagents.map(\.phase) == [.known(roster)], "\(String(describing: session()?.subagents))")
        let turn = try #require(session()?.turnStartedAt), answered = try #require(try transcript(session()?.sessionFile).recap.answeredAt)
        #expect(turn <= answered, "\(turn) \(answered)")
    }

    func transcript(_ file: URL?) throws -> HistoryUpdate {
        try History.index(file: try #require(file), agent: .claudeCode, from: nil, files: files)
    }

    func index(_ file: URL?) async throws {
        let update = try transcript(file)
        let session = IndexedSession(
            id: try #require(update.checkpoint.sessionID), path: update.file.path, cwd: work.path, lastActivityAt: .now, agent: .claudeCode)
        try await store.upsertSessions([SessionUpsert(session: session, checkpoint: try JSONEncoder().encode(update.checkpoint), transcript: nil)], host: "mac")
    }

    func waitForDraftLanded(_ id: Session.ID) async throws {
        let file = bridge.session(id: id)?.sessionFile
        var newest: ChatMessage?
        try await eventually("回答落盘") {
            newest = (try? transcript(file))?.messages.last { $0.role == .known(.pi) }
            return newest.map { $0.at >= start(of: id) } ?? false
        }
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return }
        #expect(draft.landed(newestReply: newest?.at, record: newest?.id), "正在说的话起点 \(draft.since.timeIntervalSince1970)，最近一条回答 \(String(describing: newest?.at.timeIntervalSince1970))")
    }

    private func start(of id: Session.ID) -> Date {
        log.changes.compactMap { if case .stateChanged(let session, _) = $0, session.id == id, session.state.isWorking { session.stateSince } else { nil } }
            .last ?? .distantPast
    }
}
#endif
