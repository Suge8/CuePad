#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation
import Observation
import os

/// 一个"在这台 Mac 上值班"的时段：Cue 运行在这台 Mac 且已启用时由 `CueService` 起一个，不再运行在这里时停掉。一个班次是一个大脑进程（`HostedSession`）；
/// 对话、看板、"等你"与记忆在库里，跨班次、跨重启的对账进度在 `Progress`（`keeper.json`）。库一变（订阅）、大脑有事件、唯一的定时器（`timer`）到点都对一次账（`reconcile`）。
///
/// 状态与转换（`Snapshot.State`）：
///
/// | 状态 | 怎么认 | 出路 |
/// |---|---|---|
/// | 起大脑中 `starting` | `Phase.starting` | 起好 → 值班空闲；起不来 → 等重起 |
/// | 值班空闲 `idle` | 在班、没有 `turn`、没有要重来的（`setbacks`） | 醒来或你插话 → 一轮在跑；规矩、设置或大脑要换 → 起大脑中；停用 → 不值班 |
/// | 一轮在跑 `turn` | 有 `turn` | 做完 → 值班空闲；出错 → 歇着等重来或卡住；换了家、工具服务没了 → 做完就换班；发不进、进程退出、看门狗（`CueTiming.silence`）→ 等重起 |
/// | 做完就换班 `retiring` | `Shift.retiring` | 这一轮做完 → 起大脑中 |
/// | 等重起 `restarting` | `Phase.restarting` | 到点、你发话、改设置 → 起大脑中；没有终态，快的用完转慢的一直试 |
/// | 歇着等重来 `resting` | 空闲且有要重来的、没卡住 | 到点（你的话：到点或你又说了新的）→ 一轮在跑；会话动静与巡视的被新变化取代、定时被你忘掉或改到以后 → 值班空闲 |
/// | 卡住 `stalled` | 空闲且有要重来的卡住了（额度、登录，`stuck`） | 慢速周期到点（先按绕行换家，`Detour`）→ 一轮在跑 |
/// | 不值班 `off` | `run` 返回 | 终态 |
///
/// 做梦（`dreams`）是旁路：值班空闲时另起一次性大脑，`CueTiming.silence` 内做不完就停掉。
/// 醒来的活做完才消费：定时、刚启用、你的话在承接它的一轮好好做完之前，库里一直还欠着（过点的定时、没招呼过的启用、没送达的话），
/// 崩溃、重启、换到别的 Mac 都从库里接着做（至少一次）；要重来的（`setbacks`）只在内存里记退避。
/// 你的话只经 `hand` 交出去：先记送达再发，没答上的随班次退回（`giveBack`），至少答一次。
@Observable
final class CueKeeper {
    /// 冷、热巡视每段空闲各至多一次，每天合起来至多这么多次：巡视是 Cue 自己找活，多了只是花钱打扰
    nonisolated static let patrolsPerDay = 3
    nonisolated static let roundsKept = 50

    struct Setup {
        var recorder: StateRecorder
        /// 找起大脑要的可执行文件等（不问登录）
        var launch: @Sendable (AgentKind) async throws -> CueLaunch?
        var helper: URL
        /// App 正在用的资料库目录：MCP 服务经 `CUEPAD_LIBRARY_DIR` 打开同一个库
        var library: URL
        var piAgentDirectory: URL
        var timing: CueTiming
        /// 你的消息里的附件取到这台 Mac 上（`SyncDriver.fetchFile`）
        var fetchFile: FileFetching

        /// Cue 自己的目录（在资料库目录里）：`work` 是大脑的工作目录（空的），`keeper.json` 是跨班次的对账进度
        var directory: URL { library.appending(path: "Cue", directoryHint: .isDirectory) }
    }
    var store: CueStore { setup.recorder.store }
    /// 对账用的此刻：资料库与 App 共用的钟（`CueStore.timing`，测试换成能往前跳的）。看门狗另按醒着的时长量（`CueTiming.awake`）。
    var now: Date { store.timing.now() }

    nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "cue")

    let setup: Setup
    private let inputs: AsyncStream<Input>
    let input: AsyncStream<Input>.Continuation
    var progress: Progress
    var phase = Phase.starting(failures: 0)
    var brainSettings: BrainSettings?
    var shifts = 0
    /// 最近告诉过你的那个错（`ErrorSummary.line`）：同一个错一轮轮重复（如额度）只说一次
    var toldFailure: String?
    var setbacks: [Setback] = []
    /// 下一件要重来的：到点最早的
    var setback: Setback? { setbacks.min { ($0.retryAt ?? .distantFuture) < ($1.retryAt ?? .distantFuture) } }
    /// 额度、登录卡住：要重来的只按慢速周期重来，新定时等它们做完
    var stuck: Bool { setbacks.contains(where: \.stuck) }

    /// 这件活出错是第一次（唯一的判定）：先不说、隔 `CueTiming.retryWake` 再来一次都看它。
    func firstError(_ wake: CueWake) -> Bool { !setbacks.contains { $0.wake == wake } }

    func edit(_ wake: CueWake, _ change: (inout Setback) -> Void) {
        setbacks = setbacks.map { held in
            var held = held
            if held.wake == wake { change(&held) }
            return held
        }
    }
    /// 对账的唯一定时器（`schedule`），每次对账重排成最早的那个（`alarm`）
    var timer: Task<Void, Never>?
    /// 最近一次大脑事件（或一轮开始）在看门狗的钟上的时刻（`CueTiming.awake`）：看门狗从它算（`alarm`）
    @ObservationIgnored var heardAt: SuspendingClock.Instant
    /// 这次故障里告诉过你什么：换了一家（`failOver`），或起不来、卡住了（`tellDown`，额度登录没得换时的那个错）；好好做完的那一轮说一句恢复了就清掉（`recovered`）
    @ObservationIgnored var outage: Outage?

    enum Outage {
        /// 说过换到哪家接着干：之后那家起不来照样说起不来
        case switched
        /// 说过起不来、卡住：这次故障里不再说
        case down
    }
    /// 断了的那一轮的错：退回重交的你的话、重读变化醒来的那一轮随信封交给大脑（`CueEnvelope.Input.retrying`），交出去就清掉。
    /// 只在内存：重来的那几件各自带着自己的错（`Setback.failure`）
    @ObservationIgnored var retrying: String?
    /// 最近一次出错与换大脑：写进健康（`health`）
    @ObservationIgnored var trouble: CueHealth.Failure?
    @ObservationIgnored var failover: CueHealth.Failover?
    @ObservationIgnored var writtenHealth: CueHealth?
    /// 要退回没送达、还没退回成的你的话（`giveBack`）：退回时库没写成就留在这里，落盘（`save`），退回写成才删
    @ObservationIgnored var owed: Set<UUID> = []
    /// 好好做完、还没消费成的定时（`fireCueSchedules` 没写成）：对账时再写；在这里的不再叫醒（`step`）。崩溃丢了它，那一行还过点，再做一次
    @ObservationIgnored var unfired: [CueFire] = []
    /// 正在招呼的那一次启用（`CueProfile.enabledAt`）：招呼的一轮好好做完记进 `Progress.greeted`
    @ObservationIgnored var greeting: Date?
    /// 他发起的一轮停下已对到的写入序号（`CueStore.leaveHisStops`）；nil 是这次上班还没对过，从变化的基线算起
    @ObservationIgnored var handedOver: Int?
    private var history: [CueRound] = []
    @ObservationIgnored private var roundCount = 0
    /// 你的话里的附件正在旁边取的（`ready(_:)`）与取不来、照交的
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

    /// 值班对外的样子（只读投影）：测试与评测只读它，内部字段改名、改形状不牵动它们。
    struct Snapshot {
        /// 头注释状态表里的那一格（不值班时没有值班，读不到它）
        enum State: Equatable {
            case starting, idle, turn, retiring, resting, stalled
            case restarting(at: Date)
        }

        var state: State
        /// 要重来的几件
        var setbacks: [Setback]
        /// 在跑的那一轮
        var turn: CueRound?
        /// 最近的几轮，在跑的那一轮在最后
        var rounds: [CueRound]
        /// 这一次启用已招呼过（或手上没事不用招呼）
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
    /// 在回答你的这一轮正在说的话（只在内存，不进 `cueState`、不入库、不同步）：只有 Cue 页末尾读它，出字时对话列表不重算。
    /// 说完的留着，由 Cue 页在对话里出现它之后换下；下一轮开始、大脑出问题时清掉。只显示在回答你的一轮（`Turn.answersYou`）：
    /// Cue 自己醒来的一轮最后的话不写进对话，显示了就落不了库。
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

    /// 值班到 `stop()` 或任务取消，返回前停掉大脑。
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
            // 上一次没收好尾（崩溃、强杀，没走到 `retire`）时交出去没答上的你的话：退回没送达，这次重新交
            await giveBack(progress.unanswered ?? [])
            // 一上班就是歇着：上一次没收好尾（崩溃）留下的"在想"马上清掉，不等大脑起好
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
        // 不再值班（停用、换手、App 退出）：在跑的那一轮没答上的你的话退回；它承接的定时、启用在库里还欠着，下次值班（哪台都行）接着做
        if let shift { await retire(shift) }
        clearHealth()
    }

    /// 不再值班；返回的过程等大脑退出（不需要主线程，退出收尾时在主线程之外等）。
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
