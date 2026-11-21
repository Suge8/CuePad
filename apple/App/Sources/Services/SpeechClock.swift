import CueStore
import Foundation
import Observation

@Observable
final class SpeechClock {
    private(set) var moment: Speech.Moment
    @ObservationIgnored private var waiting: [Awaiting] = []
    @ObservationIgnored private var alarm: Task<Void, Never>?
    @ObservationIgnored private let alwaysReachable: Bool
    @ObservationIgnored private let timing: Timing

    nonisolated enum Awaiting: Equatable, Sendable {
        case request(deadline: Date?)
        case cue(said: Date, reachedServer: Bool, host: String?)
    }

    init(localHost: String?, reachable: Bool, alwaysReachable: Bool, timing: Timing) {
        self.alwaysReachable = alwaysReachable
        self.timing = timing
        let now = timing.now()
        moment = Speech.Moment(now: now, reachableSince: reachable || alwaysReachable ? now : nil, localHost: localHost)
    }

    func setReachable(_ reachable: Bool) {
        guard !alwaysReachable, reachable != (moment.reachableSince != nil) else { return }
        let now = timing.now()
        moment = Speech.Moment(now: now, reachableSince: reachable ? now : nil, localHost: moment.localHost)
        schedule()
    }

    func track(_ waiting: [Awaiting]) {
        guard waiting != self.waiting else { return }
        self.waiting = waiting
        schedule()
    }

    private func schedule() {
        alarm?.cancel()
        let deadlines = waiting.compactMap { awaiting -> Date? in
            switch awaiting {
            case .request(let deadline): deadline
            case .cue(let said, let reachedServer, let host): Speech.deadline(said: said, delivered: nil, reachedServer: reachedServer, host: host, at: moment)
            }
        }
        let now = timing.now()
        if deadlines.contains(where: { $0 > moment.now && $0 <= now }) { moment.now = now }
        guard let next = deadlines.filter({ $0 > now }).min() else { return }
        alarm = Task { [weak self, timing] in
            guard (try? await timing.sleepUntil(next)) != nil else { return }
            self?.schedule()
        }
    }
}

extension AppServices {
    func startSpeechClock() {
        follow(reporting: { .syncUnavailable(String(localized: "读取在等回执的话失败，到点不再翻状态、不再主动拉取：\(String(describing: $0))")) }) {
            for try await open in self.store.observe({ store in
                let requests = try store.deliveryRequests().filter(\.isOpen)
                let cueHost = try store.cueProfile()?.hostID
                let toCue = try store.cueMessagesToDeliver().filter { $0.author == .known(.you) }
                let waiting = requests.map { SpeechClock.Awaiting.request(deadline: Speech.deadline($0)) }
                    + toCue.map { SpeechClock.Awaiting.cue(said: $0.createdAt, reachedServer: $0.reachedServer, host: cueHost) }
                let active = requests.contains { Speech.trip($0, at: .always(at: store.timing.now())).inTransit }
                return OpenSpeech(open: active || !toCue.isEmpty, waiting: waiting)
            }) {
                self.hasOpenDeliveries = open.open
                self.speechClock.track(open.waiting)
            }
        }
    }

    private nonisolated struct OpenSpeech: Equatable, Sendable {
        var open: Bool
        var waiting: [SpeechClock.Awaiting]
    }

    var speech: Speech.Moment { speechClock.moment }
}
