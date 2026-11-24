import CueStore
import Foundation
import Observation

@Observable
final class CueWatch {
    private(set) var name = CueDigest.empty.name
    private(set) var presence = CuePresence.derive(.empty, at: .always())
    private(set) var canHear = false
    private(set) var sending = false
    private(set) var now = CueNow.empty
    private(set) var wake: Wake?
    private var transition: Transition?
    private(set) var unread = 0
    private(set) var hostID: String?
    private(set) var hostName: String?
    var draft = ComposerDraft()
    var showsMemory = false
    var showsSchedules = false

    init(_ digest: CueDigest?, at moment: Speech.Moment, local: CueNow.Local) {
        if let digest { apply(digest, at: moment, local: local) }
    }

    var beat: CueBeat {
        if let transition, transition.until > .now { return transition.beat }
        return now.beat.composing(!draft.isEmpty(accepting: .files))
    }

    private struct Transition {
        let beat: CueBeat
        let until: Date
    }

    struct Send {
        let at: Date
        let beat: CueBeat
    }

    struct Wake: Equatable {
        let at: Date
        let seen: Date
        let sessions: [String]
    }

    func sent(_ event: Send) {
        hold(event.beat, until: event.at.addingTimeInterval(RelayFlight.launchLanding))
    }

    func follow(_ services: AppServices, launching: Launching) async throws {
        for try await seen in services.cueUpdates() {
            apply(seen.read.digest, at: seen.moment, local: seen.local, catchingUp: services.syncing.isCatchingUp(on: seen.read.digest.hostID))
            if let said = seen.read.digest.lastYou?.id { launching.observed(.cue) { $0 == said } }
        }
    }

    private func apply(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local, catchingUp: Bool = false) {
        name = digest.name
        let presence = CuePresence.derive(digest, at: moment)
        self.presence = presence
        canHear = presence != .disabled
        sending = if case .sending = presence { true } else { false }
        noteWake(digest.woke, catchingUp: catchingUp)
        let next = AppServices.cueNow(digest, at: moment, local: local).aged(to: .now)
        if !next.same(as: now) { show(next) }
        unread = digest.unread
        hostID = digest.hostID
        hostName = digest.hostName
    }

    @ObservationIgnored private var aging: Task<Void, Never>?
    @ObservationIgnored private var wokeSeen: Date?
    @ObservationIgnored private var releasing: Task<Void, Never>?

    private func noteWake(_ woke: CueDigest.Woke?, catchingUp: Bool) {
        guard let seen = wokeSeen else { return wokeSeen = woke?.at ?? .distantPast }
        guard let woke, woke.at > seen else { return }
        wokeSeen = woke.at
        guard let sessions = woke.sessions, !catchingUp else { return }
        let next = Wake(at: woke.at, seen: .now, sessions: sessions)
        wake = next
        hold(beat, until: next.seen.addingTimeInterval(RelayFlight.wakeLanding))
    }

    private func hold(_ snapshot: CueBeat, until end: Date) {
        let active = transition.flatMap { $0.until > .now ? $0 : nil }
        let end = max(active?.until ?? end, end)
        transition = Transition(beat: active?.beat ?? snapshot, until: end)
        releasing?.cancel()
        releasing = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow), tolerance: .zero)) != nil else { return }
            self?.transition = nil
        }
    }

    private func show(_ next: CueNow) {
        now = next
        aging?.cancel()
        guard let at = next.nextChange(after: .now) else { return }
        aging = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow))) != nil, let self else { return }
            show(now.aged(to: at))
        }
    }
}
