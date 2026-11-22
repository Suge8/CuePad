import CueStore
import CueSync
import Foundation

struct SessionAlert: Equatable, Identifiable {
    let id = UUID()
    let session: UUID
    let kind: AlertKind
    let title: String
    let question: String?
    let reply: String?
    let failure: String?

    init(_ state: SessionState, _ kind: AlertKind) {
        session = state.id
        self.kind = kind
        title = state.title
        question = SessionProgress.firstLine(state.question?.text)
        reply = state.answered ? SessionProgress.firstSentence(state.lastReply) : nil
        failure = state.state == .known(.error) ? SessionProgress.firstLine(state.detail) : nil
    }

    var content: (title: String, body: String) {
        AlertText.content(title: title, question: question, reply: reply, failure: failure, kind: kind)
    }

    var text: Dotted { Dotted("\(content.title)：\(content.body)") }

    var status: SessionShown.Status { Self.status(kind) }

    static func status(_ kind: AlertKind) -> SessionShown.Status {
        switch kind {
        case .waitingForUser: .asking
        case .awaitsReply: .awaitsReply
        case .settled: .unread
        }
    }
}

struct SessionAlertTracker {
    private var seen: [UUID: SessionState] = [:]
    private var left: Set<UUID> = []
    private var unanswered: Set<UUID> = []

    mutating func alerts(for live: [SessionListItem], cue: CueDuty?, since active: Date = .distantPast) -> [SessionAlert] {
        let nowLeft = Set(live.filter { cue?.leftToYou($0.state) == true }.map(\.id))
        defer {
            seen = Dictionary(live.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
            left = nowLeft
        }
        return live.compactMap { item -> SessionAlert? in
            guard let previous = seen[item.id] else { return nil }
            if nowLeft.contains(item.id), !left.contains(item.id) {
                return SessionAlert(item.state, item.state.leftAlert)
            }
            var kind = item.state.stateSince >= active ? item.state.alert(since: previous) : nil
            let settled = item.state.state == .known(.settled)
            if kind == .settled, !item.state.answered {
                unanswered.insert(item.id)
                kind = nil
            } else if kind == nil, settled, item.state.answered, unanswered.contains(item.id) {
                kind = .settled
            }
            if kind != nil || !settled { unanswered.remove(item.id) }
            return kind.map { SessionAlert(item.state, $0) }
        }
    }
}
