#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

/// 管理器的时间规则；测试缩短它们。
nonisolated struct CueTiming: Sendable {
    /// 你这么久没说话、又没有在做的事，才巡视。
    var patrolAfter: Duration = .seconds(2 * 3600)
    /// 记忆有待合并的块时，空闲这么久才叫它合并。
    var mergeAfter: Duration = .seconds(600)
    /// 提示缓存的时长（两家大脑都开了 1 小时的，见 `ClaudeBrain`、`PiBrain`）：距上一次模型请求超过它，缓存已过期，醒来就换新。
    var cacheLifetime: Duration = .seconds(3600)
    /// 大脑意外退出或起不来后，第 n 次重试前等多久；都失败就停在"起不来"。
    var restarts: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
    /// Cue 自己醒来的一轮出错后，隔这么久再醒一次（只一次）。
    var retryWake: Duration = .seconds(120)
    /// 打扰时段（本地钟点）：不巡视。通知不看它，免打扰只认系统的专注模式。
    var quietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]

    func isQuiet(_ date: Date) -> Bool { quietHours.contains(Calendar.current.component(.hour, from: date)) }

    /// `date` 起第一个不在打扰时段的时刻（落在打扰时段里就是它结束的那个整点）；一天都是打扰时段为 nil。
    func awake(from date: Date) -> Date? {
        guard isQuiet(date) else { return date }
        guard var hour = Calendar.current.dateInterval(of: .hour, for: date)?.end else { return nil }
        for _ in 0..<24 {
            if !isQuiet(hour) { return hour }
            hour += 3600
        }
        return nil
    }
}

/// 一个"在这台 Mac 上值班"的时段：Cue 运行在这台 Mac 且已启用时由 `CueService` 起一个，不再运行在这里时停掉。
/// 一个班次是一个大脑进程（`CueBrain`），系统提示在班次内不变（只带一直记着的，跨班次也不变，提示缓存一直命中）；对话、看板、"等你"与记忆都在库里，换班次、App 重启都不丢。
/// 设置（`CueProfile`，唯一的事实源）每次对账从库里读，与大脑在用的（`BrainSettings`）不同就去对上：
/// - 只换了模型或思考强度：空闲时就地交给在跑的大脑（`CueBrain.configure`），下一轮起生效，不换班次、上下文不丢；
///   大脑不认就把设置改回它在用的，并告诉你。
/// - 换了名字（在系统提示里）、Agent，或模型、强度回到运行时默认（就地取不回默认）：要换大脑。正在跑的一轮先做完、你的话先交，再按新设置起新班次。
///   大脑没在跑（等着重起、停在起不来）就直接按新设置起。
/// 换新（开新会话）只在一次醒来开始时判断，规则只在 `renewDue`：上下文到了换新线（`CueContext.renewAt`），或距上一次模型请求超过提示缓存的时长
/// （`CueTiming.cacheLifetime`：缓存过期后接着用要把整段原价重写，换新只写固定前缀与视图，从不更贵）。满足就让大脑开新会话（`CueBrain.newSession`），
/// 不多跑一轮；一直记着的在这个班次起来后变过（钉上、取消、忘掉），就改成换个班次，让系统提示跟上。
/// 新会话从哪接上只有一条规则：不论怎么来的（换新、换大脑、App 重启、意外退出后重起、起不来再试），第一条输入是记忆视图（`CueMemoryView`，一直记着的除外）、
/// 平铺的对话视图（`CueView`，最近的对话与每一轮的经过）加信封；之后同一个会话里只往后加信封。
/// 生命周期只有一个 `Phase`：起大脑中 → 值班（可能在跑一轮）→ 出问题后等着重起 → 次数用完停在起不来；Cue 此刻在做什么（`work`）由它直接得出，
/// 每次对完账写进库（`CueStore.setCueState`，同步给各端；值班结束时由 `CueService` 写回歇着）。
///
/// 对账：库一变（订阅，不轮询）、大脑有事件、定时器到点，都重新对一次账，按先后只做一件事：
/// 1. 你的消息（连同它收起的卡，`CueEnvelope.delivered`）与"等你"的回答（选的那一项）：大脑空闲就发信封醒来，正忙就插进当前这一轮；写 `deliveredAt`（回答也记在那条"等你"上）。
/// 2. 这一轮还没完就等。
/// 3. 要换大脑（见上）就停掉在跑的、按新设置起新班次。
///    刚启用（这一次启用还没醒过，含另一台 Mac 接管过来）：醒来看看你手上有哪些事。
/// 4. 提醒到点：醒来、清掉提醒。
/// 5. 有会话的事或不归没做完的事的会话有变化（`CueStore.cueChanges`：歇下的带着这一轮的回复，含会话等回答、Cue 自己发起的请求没能执行）：马上醒。
///    一轮在跑时来的变化等这一轮做完就醒，一起看（不另攒窗口：一轮的时长就是合批）。等子代理不是变化（子代理的结果交回、会话为它跑完那一轮歇下才是）；
///    等子代理停住（`CueChange.Kind.stalled`）不随写入出现，按下一次停住的时刻（`CueStore.nextCueStall`）排定时器，到点对账时它就在变化里。
///    会话停下归谁接手由 `CueStore.cueChanges` 定：归他的不叫醒 Cue，记下（`Progress.held`）等他离开再报；还在场就按最早的离开时刻排一次对账，
///    设备开着会话的记录一变也重对。
/// 6. 空闲巡视：没有在做的事（`CueStore.cueBoardActive`）、你很久没说话、不在打扰时段（`CueTiming.quietHours`），每段空闲最多一次、每天最多 3 次。
/// 7. 记忆有待合并的块且空闲够久：醒来附上合并提示（同一块一个班次只请一次）。
///
/// 回复是这一轮做完时大脑还留着的正在说的话（`CueBrainEvent.speaking`），一轮结束时才写进对话（`cueMessages` 是 Cue 对话唯一的事实源）。
/// 说的过程只在这台 Mac 的内存里给 Cue 页逐字显示（`speech`），只显示在回答你的一轮（`Turn.answersYou`）：
/// Cue 自己醒来的一轮最后的话可能被当复述不写，显示了就落不了库。
/// 回复写成什么看这一轮为什么醒（`author(of:)`）：你发起的（含插进来的话）与刚启用的写成 `cue`（回答你的那一轮的推送提示你），其余 Cue 自己醒来的写成 `note`（动态、不推送）；
/// Cue 自己醒来的一轮（含刚启用）里已经用 tell 对你说过话的，最后的回复不再写（几乎是同一句）；你发起的一轮最后的回复就是答复，照写
/// （`CueStore.replyCueRound`）。
/// 你发来的图按发给会话的同一个转换交给大脑（文字里的图片引用照留，Cue 能原样转给会话）；模型看不了图就不交，并对你说一声。
/// 基线（变化从哪算起）只在一轮做完且没出错时前移：出错的一轮里 Cue 没看完的变化下次还在。变化按本机写入序号分新旧
/// （`CueStore.lastWrite`），不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来也照样是新的。
/// Cue 自己醒来（刚启用、提醒与 5–7）的一轮出错后，隔 `CueTiming.retryWake` 再醒一次，再错就等下一个新变化；额度、登录类的错不重试。
/// 出错写一条 Cue 消息告诉你：你发起的一轮、不重试的错立刻说；会重试的那次先不说，重试也错了才说。回答你的一轮的回复与出错（一轮只响一次）、起不来都提示你（`CueMessage.urgent`）。
/// 大脑意外退出或起不来按 `CueTiming.restarts` 退避重试，
/// 那一轮里交出去的你的话清掉送达、重起后重新交；连续失败超过次数写一条 Cue 消息、停在"起不来"，等你的下一条消息再试。
/// 每一轮的经过（`rounds`）只在这里，在跑的一轮就是 `Turn.round`，做完收进最近的几轮；Mac 的"运行情况"读它；上下文随状态写进库，各端读 `CueState.context`。
/// 给人看的经过由它推出（`CueRound.process`），写在对话里这一轮开始的位置那一行上（`recordRound`）：Cue 自己醒来的一轮醒来时就写下、带着为什么醒
/// （`CueMessage.wake`：Cue 页那一节的第一行，各端画"叫醒"的那一下也读它），你发起的第一次调工具时写下；每做完一步改一次，
/// 此刻的状态记着在跑的是哪一行；各端 Cue 页读库。只看了看、没动手的一轮也留着这一行：Cue 页写"没动手"，连着几次并成一行。
@Observable
final class CueKeeper {
    nonisolated static let patrolsPerDay = 3
    /// 运行情况里留最近这么多轮
    nonisolated static let roundsKept = 50

    struct Setup {
        var store: CueStore
        /// 找起大脑要的可执行文件等（不问登录）
        var launch: @Sendable (AgentKind) async throws -> CueLaunch?
        /// `cuepad` 命令行（MCP 服务）
        var helper: URL
        /// App 正在用的资料库目录：MCP 服务经 `CUEPAD_LIBRARY_DIR` 打开同一个库
        var library: URL
        var piAgentDirectory: URL
        var timing: CueTiming
        /// 立即上传这几条（记下送达后：手机与别的 Mac 上那句话马上是已送达，排在其余待推送前面，见 `Speech`）
        var upload: @Sendable ([UUID]) async -> Void

        /// Cue 自己的目录（在资料库目录里）：`work` 是大脑的工作目录（空的），`keeper.json` 是跨班次的对账进度
        var directory: URL { library.appending(path: "Cue", directoryHint: .isDirectory) }
    }

    /// 值班的生命周期。
    private enum Phase {
        /// 正在起大脑；参数是此前连续失败了几次
        case starting(failures: Int)
        case running(Shift)
        /// 第 n 次连续失败之后，等着重起
        case restarting(Int)
        /// 次数用完，停在起不来（原因）；你的下一条消息再试
        case stuck(String)
    }

    /// 大脑用的那几项设置：起大脑时取自设置，就地换了模型、强度跟着改；与库里的设置不同就去对上。
    private nonisolated struct BrainSettings: Equatable, Sendable {
        var name: String
        var runtime: Open<AgentKind>
        var model: String?
        var effort: PiThinkingLevel?

        init(_ profile: CueProfile) {
            (name, runtime, model, effort) = (profile.name, profile.runtime, profile.model, profile.effort?.known)
        }

        /// 换成 `wanted` 要换大脑：名字在系统提示里、Agent 是另一个进程；模型、强度回到运行时默认就地也做不到。
        func needsNewBrain(for wanted: BrainSettings) -> Bool {
            wanted.name != name || wanted.runtime != runtime || (wanted.model == nil && model != nil) || (wanted.effort == nil && effort != nil)
        }
    }

    /// 一个班次：一个大脑进程与它这一段的状况。
    private struct Shift {
        let id: Int
        let brain: any CueBrain
        /// 起它时系统提示里一直记着的那几条：换新时变了就换班次（`renewDue`）
        let pinned: [UUID]
        /// 这个大脑的会话已经接上（第一条输入带过视图）；没有时下一次醒来带上
        var primed = false
        let startedAt = Date.now
        /// 这个会话从何时起（开新会话时改）：上下文用量从这里算
        var sessionSince = Date.now
        var turn: Turn?
        /// 最近一次模型请求的上下文用量与窗口（token）：随状态写进库（`CueState.context`），各端读那一份
        var context: CueContext?
        /// 最近一次模型请求的时刻（报上下文用量的那一刻）：据此判断提示缓存过没过期（`renewDue`）
        var lastRequest: Date?
        /// 这个班次里请过合并的块（同一块只请一次）
        var mergesTried: Set<[Int]> = []
        /// 起好之前连续失败的次数：一轮做完清零
        var failures: Int
    }

    /// 跨班次、跨 App 重启的对账进度（本机，只给这台 Mac 的管理器用）。
    private nonisolated struct Progress: Codable {
        /// 基线：变化从这些写入序号之后算（`advanceBaseline`）；nil 是这台 Mac 还没值过班，从上班时库里的最新写入算起
        var marks: CueMarks?
        var patrolDay: String?
        var patrols = 0
        /// 巡视过的那段空闲（从你上次说话起）
        var patrolledIdle: Date?
        /// 已为哪一次启用（`CueProfile.enabledAt`）醒来过
        var greeted: Date?
        /// 归他、等他离开再报的停下：会话 id → 那次停下的起点（`CueChanges.held`）
        var held: [String: Date] = [:]
    }

    /// 在跑的一轮。
    private struct Turn {
        /// 回复写成谁的
        var author: CueAuthor
        /// 这一轮的经过：醒来的时刻（Cue 在这之后用 tell 说过话，自己醒来的这一轮最后就不再写 note）、在用的工具、报的错都在这里
        var round: CueRound
        /// Cue 自己醒来（不是你发来消息）的这一轮为什么醒、附了什么（出错要退避、重试同一次醒来）；你发起的为 nil
        var selfStarted: (wake: CueWake, extra: String?)?
        /// 这一轮里交出去的你的消息与回答：大脑中途退出时清掉送达。Cue 自己醒来的一轮里有它，就是中途插进了你的话
        var delivered: [UUID] = []
        /// 大脑此刻正在说的话：做完时还留着的就是这一轮的回复
        var speaking: PiDraft?
        /// 醒来时读到的写入序号（读变化之前取）：这一轮做完且没出错，会话的动静从它之后算
        var mark: Int?
        /// 这一轮做完且没出错后，还要等他离开再报的那几次停下（`Progress.held`）：这一轮报了的不再记，没做完下次照样报
        var held: [String: Date]?

        /// 这一轮是在回答你：你发起的、中途插进了你的话，或接着你发起的那一轮（换新后写成 cue 的）。不是的（Cue 自己醒来、
        /// 含刚启用）已经用 tell 对你说过话，最后的回复就不再写
        var answersYou: Bool {
            guard let wake = selfStarted?.wake else { return true }
            return !delivered.isEmpty || (wake != .enabled && author == .cue)
        }

        /// 最后的话写不写进对话：回答你的一轮、刚启用的招呼照写；Cue 自己醒来的其余各轮没动过手（`CueRound.acted`）就不写——
        /// 系统提示里"什么都没做就不写"只在这里定。
        var writesReply: Bool { answersYou || selfStarted?.wake == .enabled || round.acted }
    }

    /// Cue 自己醒来的一轮出错了：之后自己醒来先等着，直到 `retryAt`（只一次）或有新变化（写入序号大于 `latest`，或在 `since` 之后才到的等子代理停住）。
    private struct Setback {
        var latest: Int?
        var since: Date
        var retryAt: Date?
        var wake: CueWake
        var extra: String?
        var author: CueAuthor
    }

    private nonisolated enum Input: Sendable {
        case kick, retry, stop
        case brain(Int, CueBrainEvent)
    }

    /// 触发对账的读数：变了就对一次账（内容不用，对账自己读）。记忆的版本在内：记一条、忘掉、合并都可能改变待合并的块。
    /// 看板只取对账用到的那一点：在不在做事（变了才可能该排巡视）；其余变化（会话歇下、事做完）都在写入序号里。
    private nonisolated struct Signal: Equatable, Sendable {
        var messages: [CueMessage]
        var active: Bool
        var memory: CueMemoryVersion
        var profile: CueProfile?
        /// 各设备开着的会话（`Viewer`）：他离开了在场的会话，要再报给 Cue
        var viewing: [String]
        /// 本机最近一次写入的序号（`CueStore.lastWrite`）：会话状态、问答，卡片的完成与层级，投送请求的状态，对话里的新消息一变它就变
        /// （晚到的变化事件时刻也可能更早，只有写入序号一定跟着变）；会话的其余列（说明、上下文、子代理的动作）怎么变都不叫醒对账
        var written: Int
    }

    private nonisolated static let log = Logger(subsystem: "com.sugeh.cuepad", category: "cue")

    private let setup: Setup
    private let inputs: AsyncStream<Input>
    private let input: AsyncStream<Input>.Continuation
    private var progress: Progress
    private var phase = Phase.starting(failures: 0)
    /// 此刻（或上一次试起）的大脑用的设置
    private var brainSettings: BrainSettings?
    private var shifts = 0
    private var lastTurnEnd = Date.now
    private var lastFailure: String?
    private var setback: Setback?
    private var timer: Task<Void, Never>?
    /// 做完的几轮，旧的在前，至多 `roundsKept`
    private var history: [CueRound] = []
    @ObservationIgnored private var roundCount = 0

    init(_ setup: Setup) {
        self.setup = setup
        (inputs, input) = AsyncStream.makeStream()
        progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: setup.directory.appending(path: "keeper.json")))) ?? Progress()
    }

    /// 最近的几轮，旧的在前，在跑的一轮在最后。
    var rounds: [CueRound] { turn.map { history + [$0.round] } ?? history }
    /// 在回答你的这一轮正在说的话（只在内存，不进 `cueState`、不入库、不同步）：只有 Cue 页末尾读它，出字时对话列表不重算。
    /// 说完的留着，由 Cue 页在对话里出现它之后换下；下一轮开始、大脑出问题时清掉。
    let speech = PiDraftFeed()

    /// Cue 此刻在做什么：一轮里在想或在用工具（连同这一轮的经过在对话里的那一行），起不来是出错（原因），其余（含起大脑、等着重起的那一下）歇着。
    private var work: (state: PiWorkState, detail: String?, row: UUID?) {
        switch phase {
        case .starting, .restarting: return (.settled, nil, nil)
        case .stuck(let reason): return (.error, reason, nil)
        case .running(let shift):
            guard let turn = shift.turn else { return (.settled, nil, nil) }
            let detail = turn.round.running.map { CueActivity.detail(tool: $0.name, arguments: $0.arguments) }
            return (detail == nil ? .thinking : .tool, detail, turn.round.row)
        }
    }

    private func beginRound(_ wake: CueWake, sent: [String], at date: Date = .now) -> CueRound {
        roundCount += 1
        return CueRound(id: roundCount, wake: wake, startedAt: date, sent: sent)
    }

    private func archive(_ round: CueRound) {
        var round = round
        round.finishedAt = .now
        round.context = shift?.context?.used
        history.append(round)
        if history.count > Self.roundsKept { history.removeFirst(history.count - Self.roundsKept) }
    }

    private func publish() async {
        do {
            let work = work
            try await setup.store.setCueState(work.state, detail: work.detail, round: work.row, context: shift?.context)
        } catch {
            Self.log.error("Cue 此刻的样子没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 值班到 `stop()` 或任务取消，返回前停掉大脑。
    func run() async {
        let (store, input) = (setup.store, input)
        await withDiscardingTaskGroup { group in
            group.addTask {
                do {
                    for try await _ in store.observe({ store in
                        Signal(
                            messages: try store.cueMessages(limit: 50), active: try store.cueBoardActive(), memory: try store.cueMemoryVersion(),
                            profile: try store.cueProfile(), viewing: try store.viewers().compactMap(\.sessionID), written: try store.lastWrite())
                    }) { input.yield(.kick) }
                } catch {
                    Self.log.error("Cue 订阅资料库失败：\(error.localizedDescription, privacy: .public)")
                }
            }
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
        input.yield(.stop)
        let wait = shift?.brain.stop()
        return { await wait?() }
    }

    // MARK: 班次

    private var shift: Shift? {
        if case .running(let shift) = phase { shift } else { nil }
    }

    private var turn: Turn? { shift?.turn }

    /// 改在跑的班次（不在值班时什么都不做）。
    private func updateShift(_ edit: (inout Shift) -> Void) {
        guard case .running(var shift) = phase else { return }
        edit(&shift)
        phase = .running(shift)
    }

    private func startShift(failures: Int = 0) async {
        phase = .starting(failures: failures)
        do {
            let profile = try await setup.store.cueProfile() ?? CueProfile()
            brainSettings = BrainSettings(profile)
            guard let runtime = profile.runtime.known, let launch = try await setup.launch(runtime) else {
                return await broke("这台 Mac 上没有找到 \(profile.runtime.rawValue)")
            }
            let work = setup.directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let memory = CueMemoryView(try await setup.store.cueMemory())
            let config = CueBrainConfig(
                runtime: runtime, executable: launch.executable, model: profile.model, effort: profile.effort?.known,
                systemPrompt: CuePrompt.system(name: profile.name, memory: memory, agents: launch.agents, runtime: runtime), workingDirectory: work,
                mcp: [setup.helper.path, "mcp"],
                environment: ["CUEPAD_LIBRARY_DIR": setup.library.path, "PI_CODING_AGENT_DIR": setup.piAgentDirectory.path, "PATH": launch.path])
            let brain = try await config.startBrain()
            shifts += 1
            let id = shifts, input = input
            phase = .running(Shift(id: id, brain: brain, pinned: memory.pinned.map(\.line.id), failures: failures))
            Task { for await event in brain.events { input.yield(.brain(id, event)) } }
            Self.log.notice("Cue 第 \(id) 个班次开始（\(runtime.rawValue, privacy: .public)）")
        } catch {
            await broke(error.localizedDescription)
        }
    }

    /// 大脑起不来、发不进去或意外退出：这一轮交出去的你的话清掉送达，退避重试，都失败就停在"起不来"。
    private func broke(_ reason: String) async {
        Self.log.error("Cue 的大脑出了问题：\(reason, privacy: .public)")
        let failures: Int
        switch phase {
        case .starting(let before): failures = before + 1
        case .running(let shift):
            if var round = shift.turn?.round {
                round.failure = round.failure ?? reason
                archive(round)
            }
            await shift.brain.stop()()
            speech.offer(nil)
            if let delivered = shift.turn?.delivered, !delivered.isEmpty {
                do {
                    try await setup.store.unmarkCueMessagesDelivered(delivered)
                } catch {
                    Self.log.error("Cue 没读完的消息没能退回：\(error.localizedDescription, privacy: .public)")
                }
            }
            failures = shift.failures + 1
        case .restarting, .stuck: return
        }
        guard failures <= setup.timing.restarts.count else {
            phase = .stuck(reason)
            await say(.cue, "我起不来了：\(reason)\n你再发一条消息，我就再试一次。", urgent: true)
            return
        }
        phase = .restarting(failures)
        let delay = setup.timing.restarts[failures - 1], input = input
        Task {
            try? await Task.sleep(for: delay)
            input.yield(.retry)
        }
    }

    private func handle(_ event: CueBrainEvent) async {
        switch event {
        // 逐字的正在说（每条带着到此为止的全文）与上下文用量，一轮几十上百条：不记
        case .speaking, .context: break
        default: Self.log.info("Cue 的大脑：\(String(describing: event).prefix(200), privacy: .private)")
        }
        switch event {
        case .turnStarted:
            speech.offer(nil)
            // 没有醒来就开始的一轮只能是插进来的你的话开的
            if turn == nil {
                let round = beginRound(.message, sent: [])
                updateShift { $0.turn = Turn(author: .cue, round: round) }
            }
        case .speaking(let draft):
            updateShift { $0.turn?.speaking = draft }
            speech.offer(turn?.answersYou == true ? draft : nil)
        case .context(let used, let window):
            updateShift {
                $0.context = CueContext(used: used, window: window ?? $0.context?.window, since: $0.sessionSince)
                $0.lastRequest = .now
            }
        case .tool(let id, let name, let arguments):
            updateShift { $0.turn?.round.calls.append(CueToolCall(id: id, name: name, arguments: arguments, startedAt: .now)) }
            await recordRound()
        case .toolDone(let id, let result, let failed):
            guard let call = turn?.round.calls.last(where: { $0.id == id && $0.finishedAt == nil }) else { return }
            let item = await CueActivity.item(tool: call.name, arguments: call.arguments, failed: failed, store: setup.store)
            updateShift { $0.turn?.round.finish(id, result: result, failed: failed, item: item) }
            await recordRound()
        case .failed(let raw):
            updateShift { $0.turn?.round.failure = raw }
            let summary = PiErrorSummary(raw)
            // Cue 自己醒来的一轮第一次出错（会重试的那种）先不说：多是网络偶发，重试也失败了再告诉你；你在等的一轮立刻说
            if turn?.selfStarted != nil, setback == nil, Self.retryable(summary) { return }
            let line = summary.kind == .other ? raw : "\(summary.title)\n\(raw)"  // 认不出的错，摘要只是原文的首行
            guard line != lastFailure else { return }  // 同一个错一轮轮重复（如额度）只说一次
            lastFailure = line
            let text = "这一轮出错了：\(line)"
            if let turn, turn.answersYou { await reply(text, in: turn) } else { await say(.cue, text) }
        case .turnFinished:
            guard let finished = turn else { return }
            await recordRound()  // 中途插了你的话：这一轮成了回答你的
            if finished.writesReply, let text = finished.speaking?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastFailure = nil
                await reply(text, in: finished)
            }
            archive(finished.round)
            updateShift {
                $0.turn = nil
                $0.failures = 0
            }
            lastTurnEnd = .now
            if let failure = finished.round.failure {
                if let woke = finished.selfStarted { await setBack(failure, retrying: woke, as: finished.author) }
            } else {
                setback = nil
                await markTold(finished.round)
                if let held = finished.held { progress.held = held }
                await advanceBaseline(from: finished.mark, seen: finished.round.startedAt)
            }
        case .exited(let reason):
            // 自己停的大脑不会走到这里（停之前已离开这个班次）：退出都是意外
            await broke(reason.map { "大脑退出了（\($0)）" } ?? "大脑退出了")
        }
    }

    /// 把在跑这一轮的经过写进对话里它那一行（`CueStore.recordCueRound`）：Cue 自己醒来的一轮醒来时已写下（`wakeUp`），你发起的第一次调工具时写下，
    /// 之后每做完一步改它。
    private func recordRound() async {
        guard let turn, !turn.round.calls.isEmpty else { return }
        do {
            let row = try await setup.store.recordCueRound(
                turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.process)
            updateShift { $0.turn?.round.row = row }
        } catch {
            Self.log.error("Cue 这一轮的经过没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 好好做完的一轮里，说话工具当场报给 Cue 的没送到：它已经知道了，不再进变化。只认做完的一轮——
    /// 工具写出了结果、这一轮却断了（大脑被杀、重起），Cue 没看到，下一轮照样报。
    private func markTold(_ round: CueRound) async {
        let told = round.calls.filter(\.failed).flatMap { CueTools.undeliveredRequests(in: $0.result ?? "") }
        do {
            try await setup.store.markCueTold(told)
        } catch {
            Self.log.error("Cue 记下已知道的失败没写成，下一轮会再报一次：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 该报给 Cue 的变化：基线之后的（到 `now` 为止到了的停住），与记着的归他的停下（`CueStore.cueChanges`）。
    private func changes(at now: Date = .now) async throws -> CueChanges {
        try await setup.store.cueChanges(after: progress.marks ?? CueMarks(0), held: progress.held, at: now)
    }

    /// 一轮做完、没出错：会话的动静从醒来时读到的写入序号之后算（这一轮里才写进库的下次还在，哪怕事件时刻更早），
    /// 完成从此刻的写入序号之后算（这一轮里多是 Cue 自己做完的），等子代理停住从醒来的时刻（`seen`，信封里的变化读到那一刻为止）之后算。
    private func advanceBaseline(from mark: Int?, seen: Date) async {
        do {
            let latest = try await setup.store.lastWrite()
            progress.marks = CueMarks(sessions: mark ?? latest, tasks: latest, stalls: seen)
        } catch {
            Self.log.error("Cue 读变化失败：\(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    /// Cue 自己醒来的一轮出错：第一次出错（且不是额度、登录）隔一会儿再醒一次，否则等新变化。
    private func setBack(_ failure: String, retrying woke: (wake: CueWake, extra: String?), as author: CueAuthor) async {
        let latest = try? await changes().due.map(\.seq).max()
        let retry = setback == nil && Self.retryable(PiErrorSummary(failure))
        setback = Setback(
            latest: latest, since: .now, retryAt: retry ? .now + setup.timing.retryWake.seconds : nil, wake: woke.wake, extra: woke.extra, author: author)
    }

    // MARK: 对账

    private func reconcile() async {
        timer?.cancel()
        timer = nil
        do {
            let store = setup.store, now = Date.now
            let profile = try await store.cueProfile() ?? CueProfile()
            await follow(BrainSettings(profile))
            // 该换新了、一直记着的又变过：换个班次（系统提示跟上），再接着对账
            if let shift, shift.turn == nil, shift.primed, renewDue(shift, now: now),
               try await CueMemoryView(store.cueMemory()).pinned.map(\.line.id) != shift.pinned {
                Self.log.notice("Cue 换新时一直记着的变了：换个班次")
                await shift.brain.stop()()
                await startShift()
                input.yield(.kick)
                return
            }
            let pending = try await store.cueMessagesToDeliver()
            if !pending.isEmpty {
                if case .stuck = phase { await startShift() }
                guard let shift else { return }
                let ids = pending.map(\.id)
                let said = CueEnvelope.delivered(pending, setAside: try await store.cueQuestionsSetAside())
                let images = await images(in: pending, for: shift.brain)
                if shift.turn != nil {
                    do {
                        try await shift.brain.send(said, images: images)
                    } catch {
                        return await broke("发不进去：\(error.localizedDescription)")
                    }
                    updateShift {
                        $0.turn?.author = .cue
                        $0.turn?.delivered += ids
                        $0.turn?.round.sent.append(said)
                    }
                    try await markDelivered(ids)
                } else {
                    _ = try await wakeUp(.message, said: said, images: images, delivering: ids)
                }
                return
            }
            guard let shift, shift.turn == nil else { return }

            if brainSettings?.needsNewBrain(for: BrainSettings(profile)) == true {
                await shift.brain.stop()()
                await startShift()
                input.yield(.kick)
                return
            }

            let messages = try await store.cueMessages(limit: 50)

            if progress.greeted != profile.enabledAt {
                progress.greeted = profile.enabledAt
                _ = try await wakeUp(.enabled)
                return
            }

            let due = try await store.dueCueReminders(at: now)
            if !due.isEmpty {
                guard try await wakeUp(.reminder(due.map(\.id))) else { return }
                for line in due { try await store.clearCueReminder(line.id) }
                return
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueReminder(after: now) { deadlines.append(next) }
            // 等子代理停住不写库：到点由定时器叫醒对账
            if let stall = try await store.nextCueStall(after: now) { deadlines.append(stall) }

            let timing = setup.timing
            let changes = try await self.changes(at: now)
            // 出错之后：有新变化就是新事件，照常；没有就等重试的时刻，过了这一次就只等新变化
            if let held = setback {
                if changes.due.contains(where: { $0.seq > held.latest ?? Int.min || ($0.kind == .stalled && $0.at > held.since) }) {
                    setback = nil
                } else if let retryAt = held.retryAt, now >= retryAt {
                    setback?.retryAt = nil
                    return _ = try await wakeUp(held.wake, as: held.author, extra: held.extra)
                } else {
                    return schedule([deadlines.min(), held.retryAt].compactMap { $0 }.min())
                }
            }
            if !changes.due.isEmpty {
                return _ = try await wakeUp(.sessionActivity(changes.due.map(CueStir.init)))
            }
            // 没叫醒 Cue：新归他的记下，不再归他的划掉（叫醒的一轮做完才换）
            if changes.held != progress.held {
                progress.held = changes.held
                save()
            }
            if let lapse = changes.lapse { deadlines.append(lapse) }

            let lastSpoke = messages.last { $0.author == .known(.you) }?.createdAt
            let idleSince = lastSpoke ?? profile.enabledAt ?? shift.startedAt
            if try await !store.cueBoardActive(), let due = patrolDue(idleSince: idleSince, now: now) {
                if due <= now {
                    let today = Self.day(now)
                    progress.patrols = (progress.patrolDay == today ? progress.patrols : 0) + 1
                    progress.patrolDay = today
                    progress.patrolledIdle = idleSince
                    return _ = try await wakeUp(.idle)
                }
                deadlines.append(due)
            }

            let memory = CueMemoryView(try await store.cueMemory())
            if let merge = memory.merges.first(where: { !shift.mergesTried.contains([$0.lo, $0.hi]) }) {
                let ready = lastTurnEnd + timing.mergeAfter.seconds
                if now >= ready {
                    updateShift { $0.mergesTried.insert([merge.lo, merge.hi]) }
                    return _ = try await wakeUp(.idle, extra: CueMemoryView.mergePrompt(merge))
                }
                deadlines.append(ready)
            }
            schedule(deadlines.min())
        } catch {
            Self.log.error("Cue 对账失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 设置里的大脑设置与在用的不同：大脑没在跑就直接按新设置起；在跑、空闲且只换了模型或强度，就地换（下一轮起生效）。
    /// 要换大脑的在对账第 3 步，等这一轮做完、你的话交完。
    private func follow(_ wanted: BrainSettings) async {
        guard let current = brainSettings, wanted != current else { return }
        switch phase {
        case .restarting, .stuck:
            await startShift()
        case .running(let shift) where shift.turn == nil && !current.needsNewBrain(for: wanted):
            do {
                try await shift.brain.configure(model: wanted.model, effort: wanted.effort)
                brainSettings = wanted
                Self.log.notice("Cue 就地换了模型或强度：\(Dotted(wanted.model ?? "默认", wanted.effort?.rawValue ?? "默认").visible, privacy: .public)")
            } catch {
                // 大脑不认：设置改回它在用的（设置跟着事实走，选择器上看到的就是在用的），告诉你一声。
                // 等回应时你又改了设置就不动：你后来的选择照常生效，下一次对账再去对上
                var restored = wanted
                (restored.model, restored.effort) = (current.model, current.effort)
                do {
                    let profile = try await setup.store.updateCueProfile { profile in
                        guard BrainSettings(profile) == wanted else { return }
                        (profile.model, profile.effort) = (current.model, current.effort.map(Open.known))
                    }
                    if BrainSettings(profile) == restored { await setup.upload([CueProfile.recordID]) }
                } catch {
                    Self.log.error("Cue 的设置没能改回在用的：\(error.localizedDescription, privacy: .public)")
                }
                await say(.cue, "没换成\(wanted.model.map { " \($0)" } ?? "")：\(error.localizedDescription)\n我还用原来的。")
            }
        case .starting, .running:
            break
        }
    }

    /// 什么时候可以巡视；这段空闲巡视过了、今天次数用完（等到明天）、整天都是打扰时段为 nil。
    private func patrolDue(idleSince: Date, now: Date) -> Date? {
        guard progress.patrolledIdle != idleSince else { return nil }
        let today = Self.day(now)
        let used = progress.patrolDay == today ? progress.patrols : 0
        let earliest = used < Self.patrolsPerDay
            ? max(now, idleSince + setup.timing.patrolAfter.seconds)
            : Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return setup.timing.awake(from: earliest)
    }

    /// 发一个信封让 Cue 醒来，这一轮的回复写成谁的按醒来原因定（`author(of:)`）；`said`、`images`、`delivering` 是随信封交出去的你的消息与回答，
    /// 发出去就记下送达。发不进去时按大脑出了问题处理，返回 false。
    private func wakeUp(
        _ wake: CueWake, as chosen: CueAuthor? = nil, said: String? = nil, images: [PiImage] = [], delivering: [UUID] = [], extra: String? = nil
    ) async throws -> Bool {
        guard let shift else { return false }
        let author = chosen ?? Self.author(of: wake)
        let store = setup.store, now = Date.now
        let mark = try await store.lastWrite()
        let board = try await store.cueBoard()
        let changes = try await self.changes(at: now)
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: now, projects: try await store.projects(),
            changes: changes.due, board: board, waiting: try await store.cueMessagesWaitingForYou(), left: try await store.cueState()?.left ?? [],
            wake: wake, reminders: try await reminders(of: wake)))
        var parts = [envelope]
        if !shift.primed || renewDue(shift, now: now) {
            if shift.primed {
                do {
                    try await shift.brain.newSession()
                } catch {
                    await broke("开不了新会话：\(error.localizedDescription)")
                    return false
                }
                Self.log.notice("Cue 换新：开了新会话")
                updateShift {
                    $0.context = nil
                    $0.lastRequest = nil
                    $0.sessionSince = now
                }
            }
            // 还没交给它的你的话不进对话视图：它们这次随信封交出去（`CueView` 只列已送达的）
            let views = [CueMemoryView(try await store.cueMemory()).viewText, CueView.render(try await store.cueMessages(limit: CueView.fetched))]
            parts.insert(contentsOf: views.compactMap { $0 }, at: 0)
        }
        if let extra { parts.append(extra) }
        if let said { parts.append(said) }
        Self.log.notice("Cue 醒来：\(String(describing: wake).prefix(60), privacy: .public)，回复写成 \(author.rawValue, privacy: .public)")
        let sent = parts.joined(separator: "\n")
        do {
            try await shift.brain.send(sent, images: images)
        } catch {
            await broke("发不进去：\(error.localizedDescription)")  // 这一轮还没开，交出去的话也还没记送达
            return false
        }
        var turn = Turn(
            author: author, round: beginRound(wake, sent: [sent], at: now), selfStarted: wake == .message ? nil : (wake, extra), delivered: delivering,
            mark: mark, held: changes.held)
        // Cue 自己醒来的一轮醒来就写下经过那一行：为什么醒在它上面，各端马上画得出叫醒的那一下
        if !turn.answersYou {
            do {
                turn.round.row = try await store.recordCueRound(nil, startedAt: now, answersYou: false, tools: nil, wake: wake)
            } catch {
                Self.log.error("Cue 这一轮的经过没能写进资料库：\(error.localizedDescription, privacy: .public)")
            }
        }
        updateShift {
            $0.primed = true
            $0.turn = turn
        }
        save()
        try await markDelivered(delivering)
        return true
    }

    /// 提醒到点的一轮要列给它的那几条记忆（带序号）；别的原因醒来没有。
    private func reminders(of wake: CueWake) async throws -> [CueIndexedLine] {
        guard case .reminder(let ids) = wake else { return [] }
        return try await setup.store.cueLines(ids)
    }

    /// 这次醒来要先开新会话（换新，唯一规则）：上下文到了换新线，或距上一次模型请求超过提示缓存的时长（缓存已过期，接着用要把整段原价重写；
    /// 换新只写固定前缀与视图，从不更贵）。还没请求过模型的会话不换。
    private func renewDue(_ shift: Shift, now: Date) -> Bool {
        guard let used = shift.context?.used, let last = shift.lastRequest else { return false }
        return used >= CueContext.renewAt || now.timeIntervalSince(last) > setup.timing.cacheLifetime.seconds
    }

    /// 记下送达并立即上传（不等上传完就接着对账）。
    private func markDelivered(_ ids: [UUID]) async throws {
        try await setup.store.markCueMessagesDelivered(ids)
        guard !ids.isEmpty else { return }
        let upload = setup.upload
        Task { await upload(ids) }
    }

    /// 你的消息里的图，按发给会话的同一个转换取出、交给大脑；文字里的图片引用照留（Cue 转给会话时原样写进去）。
    /// 模型看不了图、或图不在这台 Mac 上，不交图并对你说一声，不悄悄丢掉。
    private func images(in pending: [CueMessage], for brain: any CueBrain) async -> [PiImage] {
        let contents = pending.filter { $0.author == .known(.you) }.map { SendContent(stored: $0.text) }.filter(\.hasImages)
        guard !contents.isEmpty else { return [] }
        guard brain.seesImages else {
            await say(.cue, "我现在用的模型看不了图，你发的图我看不到；要我看图，换个能看图的模型。图我还能原样转给会话。")
            return []
        }
        do {
            return try contents.flatMap { try $0.piImages(from: setup.store.files) }
        } catch {
            await say(.cue, "你发的图没能交给我：\(error.localizedDescription)")
            return []
        }
    }

    /// 这一轮写给你的话（回复、回答你的一轮出错）：提不提示你、一轮只响一次都在 `CueStore.replyCueRound`。
    private func reply(_ text: String, in turn: Turn) async {
        do {
            try await setup.store.replyCueRound(startedAt: turn.round.startedAt, reply: text, as: turn.author, answersYou: turn.answersYou)
        } catch {
            Self.log.error("Cue 这一轮的话没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// `urgent`：要提示你（`CueMessage.urgent`）。
    private func say(_ author: CueAuthor, _ text: String, urgent: Bool = false) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await setup.store.addCueMessage(author, text: text, urgent: urgent)
        } catch {
            Self.log.error("Cue 的消息没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func schedule(_ date: Date?) {
        guard let date else { return }
        let input = input, delay = max(0, date.timeIntervalSinceNow) + 0.05
        timer = Task {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            input.yield(.kick)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: setup.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(progress).write(to: setup.directory.appending(path: "keeper.json"), options: .atomic)
        } catch {
            Self.log.error("Cue 的对账进度没能存下：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 这一轮的回复写成谁的：你发来消息、刚启用（你正看着屏幕）写成 cue；其余 Cue 自己醒来的写成 note。
    private static func author(of wake: CueWake) -> CueAuthor {
        switch wake {
        case .message, .enabled: .cue
        case .sessionActivity, .idle, .reminder: .note
        }
    }

    /// 重试可能好的错：额度、登录类的不算。
    private static func retryable(_ summary: PiErrorSummary) -> Bool { summary.kind != .quota && summary.kind != .authentication }

    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}
#endif
