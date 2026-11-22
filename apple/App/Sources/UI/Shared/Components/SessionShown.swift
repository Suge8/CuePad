import CueStore
import Foundation

nonisolated extension SessionState {
    func isWaking(by delivery: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        DeliveryShown.phase(of: delivery, for: self, at: moment) == .inTransit(.waking)
    }

    func staysEnded(by delivery: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        state == .known(.ended) && !isWaking(by: delivery, at: moment)
    }
}

nonisolated extension SessionState {
    func macOff(at moment: Speech.Moment) -> String? {
        moment.seesPresence(of: hostID) ? offlineMac : nil
    }
}

nonisolated extension SessionListItem {
    func isCurrent(at moment: Speech.Moment) -> Bool {
        state.state != .known(.ended) || state.isWaking(by: delivery, at: moment)
    }

    static func undelivered(_ items: [SessionListItem], at moment: Speech.Moment) -> [String: Int] {
        Dictionary(items.compactMap { item in
            let count = item.undelivered(at: moment)
            return count > 0 ? (item.state.sessionID, count) : nil
        }) { first, _ in first }
    }
}

nonisolated extension SessionState {
    static func inListOrder<Item>(
        _ items: [Item], state: KeyPath<Item, SessionState>, deliveries: [String: DeliveryRequest] = [:], cue: CueDuty? = nil,
        at moment: Speech.Moment
    ) -> [Item] {
        items.enumerated()
            .map { index, item in
                let session = item[keyPath: state]
                let shown = SessionShown(session, delivery: deliveries[session.sessionID], cue: cue, at: moment)
                let waited = shown.status == .awaitsReply ? session.stateSince : .distantPast
                return (rank: shown.rank, waited: waited, offset: index, item: item)
            }
            .sorted { ($0.rank, $0.waited, $0.offset) < ($1.rank, $1.waited, $1.offset) }
            .map(\.item)
    }

}

nonisolated enum DeliveryShown: Hashable, Sendable {
    case preparing(String)
    case inTransit(Transit)
    case delivered
    case failed(Speech.Failure)

    enum Transit: Hashable, Sendable {
        case sending
        case sent
        case delivering
        case waking
        case unconfirmed

        var label: String {
            switch self {
            case .sending: String(localized: "发送中")
            case .sent: String(localized: "已发出")
            case .delivering: String(localized: "送达中")
            case .waking: String(localized: "正在唤醒")
            case .unconfirmed: String(localized: "送达未确认")
            }
        }

        var note: String {
            switch self {
            case .sending: String(localized: "你的话发送中")
            case .sent: String(localized: "你的话已发出")
            case .delivering: String(localized: "你的话送达中")
            case .waking: String(localized: "你的话正在唤醒")
            case .unconfirmed: String(localized: "你的话送达未确认")
            }
        }

        static func of(_ request: DeliveryRequest, session: SessionState?, trip: Speech.Trip) -> Transit {
            if session?.state == .known(.ended) { return .waking }
            if !request.isWithdrawable { return .delivering }
            return trip == .sent ? .sent : .sending
        }
    }

    static func phase(of request: DeliveryRequest?, for session: SessionState, seen: Date? = nil, at moment: Speech.Moment) -> DeliveryShown? {
        guard let request, let mode = request.mode.known, DeliveryMode.toSession.contains(mode) else { return nil }
        let trip = Speech.trip(request, at: moment)
        switch trip {
        case .preparing(let reason): return .preparing(reason)
        case .unconfirmed: return mode == .retry ? nil : .inTransit(.unconfirmed)
        case .sending, .sent:
            if session.runtimeState.isWorking && session.stateSince > request.createdAt { return nil }
            return .inTransit(.of(request, session: session, trip: trip))
        case .delivered:
            let caughtUp = session.runtimeState.isWorking || session.stateSince > (request.completedAt ?? request.createdAt)
                || session.answered(since: request.createdAt)
            return caughtUp ? nil : .delivered
        case .failed(let failure):
            return (seen ?? .distantPast) > (Speech.failedAt(request, at: moment) ?? moment.now) ? nil : .failed(failure)
        }
    }
}

nonisolated struct SessionShown: Hashable, Sendable {
    var agentBusy: Bool {
        switch status {
        case .delivery(.preparing): false
        case .working, .asking, .delivery, .unknown: true
        default: false
        }
    }

    enum Status: Hashable, Sendable {
        case delivery(DeliveryShown)
        case working(WorkState)
        case asking
        case awaitsReply
        case cueAsking
        case failed(FailureKind)
        case unread
        case idle
        case resting
        case fresh
        case ended
        case interrupted
        case unknown(macOff: String? = nil)
    }

    let status: Status
    var note: String?
    var clock: SessionClock?
    var cue: String?
    var asksForWords = false
    var speaking = false

    func speaking(_ drafting: Bool) -> SessionShown {
        var shown = self
        shown.speaking = drafting
        return shown
    }
}

nonisolated extension SessionShown {
    init(
        _ session: SessionState, delivery: DeliveryRequest? = nil, marks: SessionMarks? = nil, cue duty: CueDuty? = nil,
        at moment: Speech.Moment
    ) {
        let cue = duty?.name
        let own = SessionClock.reading(session.runtimeState, stateSince: session.stateSince, busySince: session.busySince)
        let busy = session.runtimeState.isWorking || session.runtimeState == .known(.waitingForUser)
        var reported = Self.status(of: session.runtimeState, failure: session.failure?.known)
        if let mac = session.macOff(at: moment) { reported = .unknown(macOff: mac) }
        let asked = session.waitsForCue(duty) ? Status.cueAsking : reported
        switch DeliveryShown.phase(of: delivery, for: session, seen: marks?.seen, at: moment) {
        case .failed(let failure):
            self.init(status: .delivery(.failed(failure)), clock: own, cue: cue)
        case let phase? where busy:
            let note = if case .inTransit(let transit) = phase { transit.note } else { nil as String? }
            self.init(status: asked, note: note, clock: own, cue: cue)
        case let phase?:
            let clock = delivery.map { phase == .inTransit(.unconfirmed) ? SessionClock.ago($0.createdAt) : .sent(since: $0.createdAt) }
            self.init(status: .delivery(phase), clock: clock, cue: cue)
        case nil where session.runtimeState == .known(.settled):
            let rest: Status = session.awaitsReply(duty) ? .awaitsReply : duty != nil ? .resting : session.isUnread(marks, at: moment.now) ? .unread : .idle
            self.init(status: session.hasStarted ? rest : .fresh, clock: own, cue: cue)
        case nil:
            self.init(status: asked, clock: own, cue: cue)
        }
        asksForWords = session.question?.kind == .known(.text)
    }

    init(_ session: SessionState, cue: CueDuty? = nil) {
        self.init(session, delivery: nil, cue: cue, at: .always())
    }

    init(state: Open<WorkState>) { status = Self.status(of: state, failure: nil) }

    private static func status(of state: Open<WorkState>, failure: FailureKind?) -> Status {
        switch state.known {
        case .thinking, .tool, .delegating, .compacting: .working(state.known!)
        case .waitingForUser: .asking
        case .error: .failed(failure ?? .other)
        case .settled: .idle
        case .ended: .ended
        case .interrupted: .interrupted
        case nil: .unknown()
        }
    }
}

extension Workspace {
    func shown(_ session: SessionState, delivery: DeliveryRequest?) -> SessionShown {
        SessionShown(session, delivery: delivery, marks: services.liveSessions.marks[session.sessionID], cue: cueDuty, at: services.speech)
            .speaking(speaking(session))
    }

    func shownInHeader(_ session: SessionState, delivery: DeliveryRequest?) -> SessionShown {
        SessionShown(session, delivery: delivery, marks: SessionMarks(seen: .distantFuture), cue: cueDuty, at: services.speech).speaking(speaking(session))
    }

    private func speaking(_ session: SessionState) -> Bool {
        #if os(macOS)
        services.bridge.slot(sessionID: session.sessionID)?.speaking ?? false
        #else
        false
        #endif
    }

    var cueDuty: CueDuty? { services.liveSessions.cue }

    func shown(_ item: SessionListItem) -> SessionShown { shown(item.state, delivery: item.delivery) }
}

nonisolated extension Question {
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}
