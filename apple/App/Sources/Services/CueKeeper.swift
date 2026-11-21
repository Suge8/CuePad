#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation
import Observation
import os

@Observable
final class CueKeeper {
    nonisolated static let patrolsPerDay = 3
    nonisolated static let roundsKept = 50

    struct Setup {
        var recorder: StateRecorder
        var launch: @Sendable (AgentKind) async throws -> CueLaunch?
        var helper: URL
        var library: URL
        var piAgentDirectory: URL
        var timing: CueTiming
        var fetchFile: FileFetching

        var directory: URL { library.appending(path: "Cue", directoryHint: .isDirectory) }
    }
    var store: CueStore { setup.recorder.store }
    var now: Date { store.timing.now() }

    nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "cue")

    let setup: Setup
    private let inputs: AsyncStream<Input>
    let input: AsyncStream<Input>.Continuation
    var progress: Progress
    var phase = Phase.starting(failures: 0)
    var brainSettings: BrainSettings?
    var shifts = 0
    @ObservationIgnored var detour: Detour?
    var toldFailure: String?
    var setbacks: [Setback] = []
    var setback: Setback? { setbacks.min { ($0.retryAt ?? .distantFuture) < ($1.retryAt ?? .distantFuture) } }
    var stuck: Bool { setbacks.contains(where: \.stuck) }

    func firstError(_ wake: CueWake) -> Bool { !setbacks.contains { $0.wake == wake } }

    func edit(_ wake: CueWake, _ change: (inout Setback) -> Void) {
        setbacks = setbacks.map { held in
            var held = held
            if held.wake == wake { change(&held) }
            return held
        }
    }
    var timer: Task<Void, Never>?
    @ObservationIgnored var heardAt: SuspendingClock.Instant
    @ObservationIgnored var outage: Outage?

    enum Outage {
        case switched
        case down
    }
    @ObservationIgnored var retrying: String?
    @ObservationIgnored var trouble: CueHealth.Failure?
    @ObservationIgnored var failover: CueHealth.Failover?
    @ObservationIgnored var writtenHealth: CueHealth?
    @ObservationIgnored var owed: Set<UUID> = []
    @ObservationIgnored var claimed = false
    @ObservationIgnored var unfired: [CueFire] = []
    @ObservationIgnored var greeting: Date?
    @ObservationIgnored var handedOver: Int?
    private var history: [CueRound] = []
    @ObservationIgnored private var roundCount = 0
    @ObservationIgnored var fetchingFiles: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var unfetchable: Set<UUID> = []

    init(_ setup: Setup) {
        self.setup = setup
        heardAt = setup.timing.awake()
        (inputs, input) = AsyncStream.makeStream()
        do {
            progress = try JSONDecoder().decode(Progress.self, from: Data(contentsOf: setup.directory.appending(path: "keeper.json")))
        } catch CocoaError.fileReadNoSuchFile {
            progress = Progress()
        } catch {
            Self.log.error("Cue 的对账进度读不出，从头算起：\(error.localizedDescription, privacy: .public)")
            progress = Progress()
        }
    }

    struct Snapshot {
        enum State: Equatable {
            case starting, idle, turn, retiring, resting, stalled
            case restarting(at: Date)
        }

        var state: State
        var setbacks: [Setback]
        var turn: CueRound?
        var rounds: [CueRound]
        var greeted: Bool
    }

    var snapshot: Snapshot {
        let state: Snapshot.State = switch phase {
        case .starting: .starting
        case .restarting(_, _, let at): .restarting(at: at)
        case .running(let shift) where shift.retiring: .retiring
        case .running(let shift) where shift.turn != nil: .turn
        case .running: stuck ? .stalled : setbacks.isEmpty ? .idle : .resting
        }
        return Snapshot(
            state: state, setbacks: setbacks, turn: turn?.round, rounds: turn.map { history + [$0.round] } ?? history,
            greeted: progress.greeted != nil)
    }
    let speech = LiveDraftFeed()

    var work: (state: WorkState, detail: String?, step: CueActivity.Touch?, row: UUID?) {
        switch phase {
        case .restarting(let failures, let reason, _) where setup.timing.isDown(after: failures): return (.error, reason.text, nil, nil)
        case .starting, .restarting: return (.settled, nil, nil, nil)
        case .running(let shift):
            guard let turn = shift.turn else { return (.settled, nil, nil, nil) }
            guard let call = turn.round.running else { return (.thinking, nil, nil, turn.round.row) }
            return (.tool, call.detail, call.step, turn.round.row)
        }
    }

    func beginRound(_ wake: CueWake, sent: [String], at date: Date) -> CueRound {
        roundCount += 1
        return CueRound(id: roundCount, wake: wake, startedAt: date, sent: sent)
    }

    func archive(_ round: CueRound) {
        var round = round
        round.finishedAt = now
        round.context = shift?.context?.used
        history.append(round)
        if history.count > Self.roundsKept { history.removeFirst(history.count - Self.roundsKept) }
    }

    private func publish() async {
        do {
            let work = work
            try await setup.recorder.updateCue(work.state, detail: work.detail, step: work.step, round: work.row, context: shift?.context)
        } catch {
            Self.log.error("Cue 此刻的样子没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
        writeHealth()
    }

    func run() async {
        let (store, input) = (self.store, input)
        await withDiscardingTaskGroup { group in
            group.addTask {
                do {
                    for try await _ in store.observe({ store in
                        Signal(
                            toDeliver: try store.cueMessagesToDeliver().map(\.id), lastYou: try store.cueLastYou()?.said,
                            active: try store.cueBoardActive(), memory: try store.cueMemoryVersion(), profile: try store.cueProfile(),
                            written: try store.lastWrite(), runtime: try store.runtimeDeadlines())
                    }) { input.yield(.kick) }
                } catch {
                    Self.log.error("Cue 订阅资料库失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            group.addTask { await self.dreams() }
            await publish()
            if progress.marks == nil {
                do {
                    progress.marks = CueMarks(try await store.lastWrite(), stalls: now)
                    save()
                } catch {
                    Self.log.error("Cue 读写入序号失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            await startShift()
            await publish()
            loop: for await next in inputs {
                switch next {
                case .stop: break loop
                case .kick, .settle: break
                case .brain(let id, let event): if shift?.id == id { await handle(event) }
                }
                await reconcile()
                await publish()
                if case .settle(let done) = next { done.resume() }
            }
            group.cancelAll()
        }
        timer?.cancel()
        if let shift { await retire(shift) }
        clearHealth()
    }

    @discardableResult
    func stop() -> @Sendable () async -> Void {
        fetchingFiles.values.forEach { $0.cancel() }
        fetchingFiles = [:]
        input.yield(.stop)
        let wait = shift?.brain.stop()
        return { await wait?() }
    }
}
#endif
