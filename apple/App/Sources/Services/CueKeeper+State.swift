#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

extension CueKeeper {
    enum Phase {
        case starting(failures: Int)
        case running(Shift)
        case restarting(failures: Int, reason: ShownText, at: Date)
    }

    nonisolated struct BrainSettings: Equatable, Sendable {
        var name: String
        var runtime: Open<AgentKind>
        var model: String?
        var effort: ThinkingLevel?
        var fast: Bool

        init(_ profile: CueProfile, _ detour: Detour? = nil) {
            (name, runtime, model, effort, fast) = (profile.name, profile.runtime, profile.model, profile.effort?.known, profile.fast)
            if let to = detour?.to, profile.runtime.known != to { (runtime, model, fast) = (.known(to), nil, false) }
        }

        func needsNewBrain(for wanted: BrainSettings) -> Bool { wanted.profile.needsNewBrain(from: profile) }

        private var profile: CueProfile { CueProfile(name: name, runtime: runtime, model: model, effort: effort.map(Open.known), fast: fast) }
    }

    struct Shift {
        let id: Int
        let brain: any HostedSession
        let pinned: [UUID]
        var primed = false
        let startedAt: Date
        var turn: Turn?
        var context: CueContext?
        var lastRequest: Date?
        var failures: Int
        var retiring = false
        var handed: [UUID: [UUID]] = [:]
        var taken: [UUID] = []
        var unanswered: [UUID] { (turn?.delivered ?? []) + handed.values.flatMap(\.self) + taken }
    }

    nonisolated struct Progress: Codable {
        var marks: CueMarks?
        var patrolDay: String?
        var patrols = 0
        var patrolledIdle: Date?
        var warmedIdle: Date?
        var greeted: Date?
        var heard: Int64?
    }

    nonisolated struct Detour: Equatable, Sendable {
        struct Stuck: Equatable, Sendable {
            var at: Date
            var resets: Date?
        }

        var to: AgentKind
        var stuck: [AgentKind: Stuck] = [:]

        func open(_ kind: AgentKind, at now: Date) -> Bool {
            guard let stuck = stuck[kind] else { return true }
            return stuck.resets.map { $0 <= now } ?? false
        }

        func next(from current: AgentKind, home: AgentKind?, among kinds: [AgentKind], at now: Date) -> (kind: AgentKind, open: Bool)? {
            if let home, kinds.contains(home), open(home, at: now) { return (home, true) }
            if stuck[current] == nil, kinds.contains(current) { return (current, true) }
            let last = stuck.max { $0.value.at < $1.value.at }?.key ?? current
            let split = kinds.firstIndex(of: last).map { $0 + 1 } ?? 0
            let order = kinds[split...] + kinds[..<split]
            if let fresh = order.first(where: { stuck[$0] == nil }) { return (fresh, true) }
            let passed = order.compactMap { kind in stuck[kind]?.resets.flatMap { $0 <= now ? (kind, $0) : nil } }
            if let earliest = passed.min(by: { $0.1 < $1.1 }) { return (earliest.0, true) }
            return order.first.map { ($0, false) }
        }

        func nextReset(after now: Date) -> Date? { stuck.values.compactMap(\.resets).filter { $0 > now }.min() }
    }

    struct Turn {
        var answersYou: Bool
        var round: CueRound
        var selfStarted: CueWake?
        var delivered: [UUID] = []
        var speaking: LiveDraft?
        var mark: Int?
        var stops: [CueLeft] = []
        var replay = false

        var writesReply: Bool { answersYou || selfStarted == .enabled }

        var author: CueAuthor { writesReply ? .cue : .note }
    }

    nonisolated struct Setback: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case again(at: Date)
            case slow(at: Date, stalls: Int, stuck: Bool)
            case awaitingChange
        }

        var stage: Stage
        var wake: CueWake
        var latest: Int?
        var since: Date
        var failure: String?
        var held: Set<UUID> = []
        var stops: [CueLeft] = []

        var retryAt: Date? {
            switch stage {
            case .again(let at), .slow(let at, _, _): at
            case .awaitingChange: nil
            }
        }

        var stuck: Bool {
            if case .slow(_, _, true) = stage { true } else { false }
        }

        var stalls: Int {
            if case .slow(_, let stalls, _) = stage { stalls } else { 0 }
        }

        var supersedable: Bool { Self.supersedable(wake) }

        static func supersedable(_ wake: CueWake) -> Bool {
            switch wake {
            case .sessionActivity, .idle: true
            case .enabled, .message, .schedule: false
            }
        }

        mutating func due(_ date: Date) {
            switch stage {
            case .again: stage = .again(at: date)
            case .slow(_, let stalls, let stuck): stage = .slow(at: date, stalls: stalls, stuck: stuck)
            case .awaitingChange: break
            }
        }
    }

    nonisolated enum Input: Sendable {
        case kick, stop
        case brain(Int, TurnEvent)
        case settle(CheckedContinuation<Void, Never>)
    }

    nonisolated struct Signal: Equatable, Sendable {
        var toDeliver: [UUID]
        var lastYou: Date?
        var active: Bool
        var memory: CueMemoryVersion
        var profile: CueProfile?
        var written: Int
        var runtime: [Date]
    }
}

extension CueWake {
    var fires: [CueFire] { if case .schedule(let fires) = self { fires } else { [] } }
}
#endif
