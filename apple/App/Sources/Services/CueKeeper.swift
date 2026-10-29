#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

/// 一个"在这台 Mac 上值班"的时段：Cue 运行在这台 Mac 且已启用时由 `CueService` 起一个，不再运行在这里时停掉。
/// 一个班次是一个大脑进程（`HostedSession`），系统提示在班次内不变（只带一直记着的，跨班次也不变，提示缓存一直命中）；对话、看板、"等你"与记忆都在库里，换班次、App 重启都不丢。
/// 设置（`CueProfile`，唯一的事实源）每次对账从库里读，与大脑在用的（`BrainSettings`）不同就去对上：
/// - 只换了模型或思考强度：空闲时就地交给在跑的大脑（`HostedSession.configure`），下一轮起生效，不换班次、上下文不丢；
///   大脑不认就把设置改回它在用的，并告诉你。
/// - 换了名字（在系统提示里）、Agent，或模型、强度回到运行时默认（就地取不回默认）：要换大脑。正在跑的一轮先做完、你的话先交，再按新设置起新班次。
///   大脑没在跑（等着重起、停在起不来）就直接按新设置起。
/// 换新（开新会话）只在一次醒来开始时判断，规则只在 `renewDue`：上下文到了换新线（`CueTiming.renewAt`），或距上一次模型请求超过提示缓存的时长
/// （`CueTiming.cacheLifetime`：缓存过期后接着用要把整段原价重写，换新只写固定前缀与视图，从不更贵）。满足就让大脑开新会话（`HostedSession.newSession`），
/// 不多跑一轮、不先写交接（实测缓存热时先写交接再换没有带来提升，交接还每次写超 600 字）；一直记着的在这个班次起来后变过（钉上、取消、忘掉），就改成换个班次，让系统提示跟上。
/// 新会话从哪接上只有一条规则：不论怎么来的（换新、换大脑、App 重启、意外退出后重起、起不来再试），第一条输入是记忆视图（`CueMemoryView`，一直记着的除外）、
/// 平铺的对话视图（`CueView`，最近的对话与每一轮的经过）加信封；之后同一个会话里只往后加信封。
/// 记忆的待合并的块不进 Cue 的轮：后台另起一次性的大脑合（`dreams`），不碰 Cue 的上下文与缓存，回你的那一轮不等它。
/// 生命周期只有一个 `Phase`：起大脑中 → 值班（可能在跑一轮）→ 出问题后等着重起 → 次数用完停在起不来；Cue 此刻在做什么（`work`）由它直接得出，
/// 每次对完账写进库（`PiStateRecorder.updateCue`；值班结束时由 `CueService` 写回歇着）。
///
/// 对账：库一变（订阅，不轮询）、大脑有事件、定时器到点，都重新对一次账，按先后只做一件事：
/// 1. 你的消息（连同它收起的卡，`CueEnvelope.delivered`）与"等你"的回答（选的那一项）：大脑空闲就发信封醒来，正忙就插进当前这一轮；写 `deliveredAt`（回答也记在那条"等你"上）。
/// 2. 这一轮还没完就等。
/// 3. 要换大脑（见上）就停掉在跑的、按新设置起新班次。
///    刚启用（这一次启用还没醒过，含另一台 Mac 接管过来）：醒来看看你手上有哪些事。手上什么都没有（`handsEmpty`）就不醒：
///    它只能说一句"没有在做的事"，Cue 页的空态（`CuePage`）直接告诉你能对它说什么。
/// 4. 定时到点（`CueMemoryLine`）：醒来，之后重复的推到下一次、一次性的忘掉（`CueStore.fireCueSchedules`）。定时器是睡眠也走的时钟（`schedule`）：
///    Mac 醒着、App 开着时准点；睡着或 App 没开，醒来、启动后第一次对账就到点，中间错过的几次只补一次（迟到的那句事实在叫醒原因上，`CueFire`）。
/// 5. 有会话的事或不归没做完的事的会话有变化（`CueStore.cueChanges`：歇下的带着这一轮的回复，含会话等回答、Cue 自己发起的请求没能执行）：马上醒。
///    一轮在跑时来的变化等这一轮做完就醒，一起看（不另攒窗口：一轮的时长就是合批）。等子代理不是变化（子代理的结果交回、会话为它跑完那一轮歇下才是）；
///    等子代理停住（`CueChange.Kind.stalled`）不随写入出现，按下一次停住的时刻（`CueStore.nextCueStall`）排定时器，到点对账时它就在变化里。
///    他发起的一轮停下不等 Cue：每次对账先当场留给他回（`CueStore.leaveHisStops`，Cue 在跑一轮也照做），Cue 之后看过再定收不收回；
///    他停下时在场的先不叫醒 Cue，记下（`Progress.held`）等他离开再报（`CueStore.cueChanges`）；还在场就按最早的离开时刻排一次对账，
///    设备开着会话的记录一变也重对。
/// 6. 空闲巡视：没有在做的事（`CueStore.cueBoardActive`）、你最近一句（`CueStore.cueLastYou`，还没说过从启用算起）之后很久没说话、不在打扰时段（`CueTiming.quietHours`），每段空闲最多一次、每天最多 3 次；
///    手上什么都没有（`handsEmpty`，同刚启用）不巡视。
///
/// 回复是这一轮做完时大脑还留着的正在说的话（`TurnEvent.speaking`），一轮结束时才写进对话（`cueMessages` 是 Cue 对话唯一的事实源）。
/// 说的过程只在这台 Mac 的内存里给 Cue 页逐字显示（`speech`），只显示在回答你的一轮（`Turn.answersYou`）：
/// Cue 自己醒来的一轮最后的话不写，显示了就落不了库。
/// 回复写成什么看这一轮为什么醒（`author(of:)`）：你发起的（含插进来的话）与刚启用的写成 `cue`（回答你的那一轮的推送提示你）；Cue 自己醒来的其余各轮最后的话一律不写，
/// Cue 页照它的动作写这一轮，要你知道就 tell。刚启用那一轮里已经用 tell 对你说过话的，招呼不再写（几乎是同一句）；你发起的一轮最后的回复就是答复，照写
/// （`CueStore.replyCueRound`）。
/// 会话停下叫醒的一轮正常做完时，没给去处的停下（对它说话、留给你回、收掉、做完它的事、就它问你都没做）CuePad 替它留给你回（`leaveUnattended`）：
/// 会话停下后一定有去处，不会歇在看板上没人管。
/// 你发来的图按发给会话的同一个转换交给大脑（文字里的图片引用照留，Cue 能原样转给会话）；模型看不了图就同文件一样把路径写进信封。
/// 基线（变化从哪算起）只在一轮做完且没出错时前移：出错的一轮里 Cue 没看完的变化下次还在。变化按本机写入序号分新旧
/// （`CueStore.lastWrite`），不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来也照样是新的。
/// Cue 自己醒来（刚启用、定时与 5–6）的一轮出错后，隔 `CueTiming.retryWake` 再醒一次，再错就等下一个新变化；额度、登录类的错不重试。
/// 出错写一条 Cue 消息告诉你：你发起的一轮、不重试的错立刻说；会重试的那次先不说，重试也错了才说。回答你的一轮的回复与出错（一轮只响一次）、起不来都提示你（`CueMessage.urgent`）。
/// 大脑意外退出或起不来按 `CueTiming.restarts` 退避重试，
/// 那一轮里交出去的你的话清掉送达、重起后重新交；连续失败超过次数写一条 Cue 消息、停在"起不来"，等你的下一条消息再试。
/// 每一轮的经过（`rounds`）只在这里，在跑的一轮就是 `Turn.round`，做完收进最近的几轮；Mac 的"运行情况"读它；上下文随状态写进库，各端读 `CueState.context`。
/// 给人看的经过由它推出（`CueRound.process`），写在对话里这一轮开始的位置那一行上（`recordRound`）：Cue 自己醒来的一轮醒来时就写下、带着为什么醒
/// （`CueMessage.wake`：Cue 页那一行，各端画"叫醒"的那一下也读它），你发起的第一次调工具时写下；每做完一步改一次，
/// 此刻的状态记着在跑的是哪一行；各端 Cue 页读库。一轮做完时最后一次改这一行、写回复与歇着在同一次写入里（`finish`）：别的设备同步来时一起到，
/// "做完了"只看此刻的状态。只看了看、没动手的一轮也留着这一行：Cue 页照样一行，写叫醒它的那一处与当时出了什么事（`CueNoteLog`）。
@Observable
final class CueKeeper {
    nonisolated static let patrolsPerDay = 3
    nonisolated static let roundsKept = 50

    struct Setup {
        var recorder: PiStateRecorder
        /// 找起大脑要的可执行文件等（不问登录）
        var launch: @Sendable (AgentKind) async throws -> CueLaunch?
        var helper: URL
        /// App 正在用的资料库目录：MCP 服务经 `CUEPAD_LIBRARY_DIR` 打开同一个库
        var library: URL
        var piAgentDirectory: URL
        var timing: CueTiming
        /// 立即上传这几条（记下送达后：手机与别的 Mac 上那句话马上是已送达，排在其余待推送前面，见 `Speech`）
        var upload: @Sendable ([UUID]) async -> Void
        /// 你的消息里的附件取到这台 Mac 上（`AppServices.fetchFile`）
        var fetchFile: FileFetching

        /// Cue 自己的目录（在资料库目录里）：`work` 是大脑的工作目录（空的），`keeper.json` 是跨班次的对账进度
        var directory: URL { library.appending(path: "Cue", directoryHint: .isDirectory) }
    }
    var store: CueStore { setup.recorder.store }

    nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "cue")

    let setup: Setup
    private let inputs: AsyncStream<Input>
    let input: AsyncStream<Input>.Continuation
    var progress: Progress
    var phase = Phase.starting(failures: 0)
    /// 此刻（或上一次试起）的大脑用的设置
    var brainSettings: BrainSettings?
    var shifts = 0
    var lastFailure: String?
    var setback: Setback?
    var timer: Task<Void, Never>?
    /// 他发起的一轮停下已对到的写入序号（`CueStore.leaveHisStops`）；nil 是这次上班还没对过，从变化的基线算起
    @ObservationIgnored var handedOver: Int?
    /// 做完的几轮，旧的在前，至多 `roundsKept`
    private var history: [CueRound] = []
    @ObservationIgnored private var roundCount = 0
    /// 你的话里的附件正在旁边取的（`ready(_:)`）与取不来、照交的
    @ObservationIgnored var fetchingFiles: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var unfetchable: Set<UUID> = []

    init(_ setup: Setup) {
        self.setup = setup
        (inputs, input) = AsyncStream.makeStream()
        progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: setup.directory.appending(path: "keeper.json")))) ?? Progress()
    }

    var rounds: [CueRound] { turn.map { history + [$0.round] } ?? history }
    /// 在回答你的这一轮正在说的话（只在内存，不进 `cueState`、不入库、不同步）：只有 Cue 页末尾读它，出字时对话列表不重算。
    /// 说完的留着，由 Cue 页在对话里出现它之后换下；下一轮开始、大脑出问题时清掉。
    let speech = PiDraftFeed()

    /// Cue 此刻在做什么：一轮里在想或在用工具（连同这一轮的经过在对话里的那一行），起不来是出错（原因），其余（含起大脑、等着重起的那一下）歇着。
    var work: (state: PiWorkState, detail: String?, step: CueActivity.Touch?, row: UUID?) {
        switch phase {
        case .starting, .restarting: return (.settled, nil, nil, nil)
        case .stuck(let reason): return (.error, reason.text, nil, nil)
        case .running(let shift):
            guard let turn = shift.turn else { return (.settled, nil, nil, nil) }
            guard let call = turn.round.running else { return (.thinking, nil, nil, turn.round.row) }
            return (.tool, call.detail, call.step, turn.round.row)
        }
    }

    func beginRound(_ wake: CueWake, sent: [String], at date: Date = .now) -> CueRound {
        roundCount += 1
        return CueRound(id: roundCount, wake: wake, startedAt: date, sent: sent)
    }

    func archive(_ round: CueRound) {
        var round = round
        round.finishedAt = .now
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
                            active: try store.cueBoardActive(), memory: try store.cueMemoryVersion(),
                            profile: try store.cueProfile(), viewing: try store.viewers().compactMap(\.sessionID), written: try store.lastWrite(), runtime: try store.runtimeDeadlines())
                    }) { input.yield(.kick) }
                } catch {
                    Self.log.error("Cue 订阅资料库失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            group.addTask { await self.dreams() }
            // 一上班就是歇着：上一次没收好尾（崩溃）留下的"在想"马上清掉，不等大脑起好
            await publish()
            if progress.marks == nil {
                do {
                    progress.marks = CueMarks(try await store.lastWrite(), stalls: .now)
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
                case .kick: break
                case .retry: if case .restarting(let failures) = phase { await startShift(failures: failures) }
                case .brain(let id, let event): if shift?.id == id { await handle(event) }
                }
                await reconcile()
                await publish()
            }
            group.cancelAll()
        }
        timer?.cancel()
        await shift?.brain.stop()()
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
