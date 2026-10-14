#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation
import os

/// 管理器的时间规则；测试缩短它们。
nonisolated struct CueTiming: Sendable {
    /// 跟进的事有变化后，安静这么久才醒（又有新变化就重新计时）……
    var quiet: Duration = .seconds(20)
    /// ……但从第一处变化算起最多等这么久。
    var quietLimit: Duration = .seconds(120)
    /// 你这么久之内对 Cue 说过话，就是还在和它说话：变化先压着。
    var talking: Duration = .seconds(60)
    /// 你这么久没说话、Cue 又没在跟进任何事，才巡视。
    var patrolAfter: Duration = .seconds(2 * 3600)
    /// 记忆有待合并的块时，空闲这么久才叫它合并。
    var mergeAfter: Duration = .seconds(600)
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

/// 一个"在这台 Mac 上值班"的时段：Cue 住在这台 Mac 且已启用时由 `CueService` 起一个，设置变了或不再住这里时停掉。
/// 一个班次是一个大脑进程（`CueBrain`），系统提示在班次内不变；对话、跟进与"等你"都在库里，换班次、App 重启都不丢。
/// 生命周期只有一个 `Phase`：起大脑中 → 值班（可能在跑一轮）→ 出问题后等着重起 → 次数用完停在起不来；Cue 此刻在做什么（`work`）由它直接得出，
/// 每次对完账写进库（`CueStore.setCueState`，同步给各端；值班结束时由 `CueService` 写回歇着）。
///
/// 对账：库一变（订阅，不轮询）、大脑有事件、定时器到点，都重新对一次账，按先后只做一件事：
/// 1. 你的消息与"等你"的回答：大脑空闲就发信封醒来，正忙就插进当前这一轮；写 `deliveredAt`（回答也记在那条"等你"上）。
///    你关掉的提问不叫醒 Cue（`CueMessage.wakesCue`），随下一次醒来的信封写在变化里、记下送达。
/// 2. 这一轮还没完就等。
/// 3. 换新：本班次里出现了交接备忘（`memory renew`）就停掉大脑、起新班次，第一轮醒来带上交接。
///    刚启用（这一次启用还没醒过，含另一台 Mac 接管过来）：醒来看看你手上有哪些事。
/// 4. 提醒到点：醒来、清掉提醒。
/// 5. 跟进的事有变化（含 Cue 自己发起的请求没能执行）：攒安静窗口再醒；你还在和 Cue 说话时先压着。
///    其中有会话在等回答（如"允许使用 Bash？"）就是活被卡住了：不攒窗口、不压着，马上醒（正在跑的一轮做完就醒），连同别的变化一起看。
/// 6. 空闲巡视：没在跟进任何事、你很久没说话、不在打扰时段（`CueTiming.quietHours`），每段空闲最多一次、每天最多 3 次。
/// 7. 记忆有待合并的块且空闲够久：醒来附上合并提示（同一块一个班次只请一次）。
///
/// 回复写成什么看这一轮为什么醒（`author(of:)`）：你发起的（含插进来的话）与刚启用的写成 `cue`，其余 Cue 自己醒来的写成 `note`（折成灰色一行、不推送），
/// 换新后的第一轮跟写下交接的那一轮一样；
/// Cue 自己醒来的一轮里已经用 tell 对你说过话的，最后的回复不再写 note（几乎是同一句）。
/// 基线（变化从哪一刻算起、上次的看板）只在一轮做完且没出错时前移：出错的一轮里 Cue 没看完的变化下次还在。
/// Cue 自己醒来（刚启用、换新、提醒与 5–7）的一轮出错后，隔 `CueTiming.retryWake` 再醒一次，再错就等下一个新变化；额度、登录类的错不重试。
/// 出错写一条 Cue 消息告诉你：你发起的一轮、不重试的错立刻说；会重试的那次先不说，重试也错了才说。
/// 上下文用到 `renewAt` 后，下一次醒来的信封里提示先写交接。大脑意外退出或起不来按 `CueTiming.restarts` 退避重试，
/// 那一轮里交出去的你的话清掉送达、重起后重新交；连续失败超过次数写一条 Cue 消息、停在"起不来"，等你的下一条消息再试。
final class CueKeeper {
    /// 上下文用到这么多 token 就请 Cue 换新。
    nonisolated static let renewAt = 60_000
    nonisolated static let patrolsPerDay = 3

    struct Setup {
        var store: CueStore
        var profile: CueProfile
        /// 找起大脑要的可执行文件等（不问登录）
        var launch: @Sendable (AgentKind) async -> CueLaunch?
        /// 大脑起不来：请 `CueService` 重新查一遍本机的运行时
        var startFailed: () -> Void
        /// `cuepad` 命令行（MCP 服务）
        var helper: URL
        /// App 正在用的资料库目录：MCP 服务经 `CUEPAD_LIBRARY_DIR` 打开同一个库
        var library: URL
        var piAgentDirectory: URL
        /// Cue 自己的目录：`work` 是大脑的工作目录（空的），`keeper.json` 是跨班次的对账进度
        var directory: URL
        var timing: CueTiming
        /// 立即上传这几条（记下送达后：手机与别的 Mac 上那句话马上是已送达，不等引擎自己排，见 `Speech`）
        var upload: @Sendable ([UUID]) async -> Void = { _ in }
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

    /// 一个班次：一个大脑进程与它这一段的状况。
    private struct Shift {
        let id: Int
        let brain: any CueBrain
        let startedAt = Date.now
        var turn: Turn?
        var contextUsed: Int?
        /// 这个班次里请过合并的块（同一块只请一次）
        var mergesTried: Set<[Int]> = []
        /// 起好之前连续失败的次数：一轮做完清零
        var failures: Int
    }

    /// 跨班次、跨 App 重启的对账进度（本机，只给这台 Mac 的管理器用）。
    private nonisolated struct Progress: Codable {
        /// 基线：变化从这之后算（上一次做完的一轮醒来的时刻）
        var since = Date.now
        /// 基线时看板上的任务；nil 是还没醒过（不比跟进集合）
        var followed: [UUID]?
        var patrolDay: String?
        var patrols = 0
        /// 巡视过的那段空闲（从你上次说话起）
        var patrolledIdle: Date?
        /// 已为哪一次启用（`CueProfile.enabledAt`）醒来过
        var greeted: Date?
    }

    /// 在跑的一轮。
    private struct Turn {
        /// 回复写成谁的
        var author: CueAuthor
        /// 醒来（或插话开出这一轮）的时刻：Cue 在这之后用 tell 说过话，自己醒来的这一轮最后就不再写 note
        var startedAt = Date.now
        /// Cue 自己醒来（不是你发来消息）的这一轮为什么醒、附了什么（出错要退避、重试同一次醒来）；你发起的为 nil
        var selfStarted: (wake: CueWake, extra: String?)?
        /// 这一轮里交出去的你的消息、回答与关掉的提问：大脑中途退出时清掉送达
        var delivered: [UUID] = []
        /// 醒来时的基线候选：这一轮做完且没出错才前移到它
        var baseline: (since: Date, followed: [UUID])?
        /// 这一轮报的错（原文）
        var failure: String?
        /// 正在用的工具（`CueActivity.detail`）；nil 是在想
        var tool: String?
    }

    /// Cue 自己醒来的一轮出错了：之后自己醒来先等着，直到 `retryAt`（只一次）或有新变化（晚于 `latest`）。
    private struct Setback {
        var latest: Date?
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
    private nonisolated struct Signal: Equatable, Sendable {
        var messages: [CueMessage]
        var board: [CueBoardItem]
        var memory: CueMemoryVersion
        /// Cue 的请求最近一次失败：失败不一定改动看板（说话、作答没能送达），单独订阅
        var failed: Date?
    }

    private nonisolated static let log = Logger(subsystem: "com.sugeh.cuepad", category: "cue")

    private let setup: Setup
    private let inputs: AsyncStream<Input>
    private let input: AsyncStream<Input>.Continuation
    private var progress: Progress
    private var phase = Phase.starting(failures: 0)
    private var shifts = 0
    private var lastTurnEnd = Date.now
    /// 上一轮的回复写成谁的（换新时接着用）
    private var lastTurnAuthor: CueAuthor = .note
    private var lastFailure: String?
    private var setback: Setback?
    private var window: (first: Date, last: Date, latest: Date)?
    private var timer: Task<Void, Never>?

    init(_ setup: Setup) {
        self.setup = setup
        (inputs, input) = AsyncStream.makeStream()
        progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: setup.directory.appending(path: "keeper.json")))) ?? Progress()
    }

    /// Cue 此刻在做什么：一轮里在想或在用工具，起不来是出错（原因），其余（含起大脑、等着重起的那一下）歇着。
    private var work: (state: PiWorkState, detail: String?) {
        switch phase {
        case .starting, .restarting: (.settled, nil)
        case .running(let shift): shift.turn.map { $0.tool == nil ? (.thinking, nil) : (.tool, $0.tool) } ?? (.settled, nil)
        case .stuck(let reason): (.error, reason)
        }
    }

    private func publish() async {
        do {
            try await setup.store.setCueState(work.state, detail: work.detail)
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
                            messages: try store.cueMessages(limit: 50), board: try store.cueBoard(), memory: try store.cueMemoryVersion(),
                            failed: try store.lastCueRequestFailure())
                    }) { input.yield(.kick) }
                } catch {
                    Self.log.error("Cue 订阅资料库失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            // 一上班就是歇着：上一次没收好尾（崩溃）留下的"在想"马上清掉，不等大脑起好
            await publish()
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

    /// `wake`：新班次第一轮醒来的原因（换新），回复写成 `author` 的。
    private func startShift(failures: Int = 0, wake: CueWake? = nil, author: CueAuthor = .note) async {
        phase = .starting(failures: failures)
        let profile = setup.profile
        guard let runtime = profile.runtime.known, let launch = await setup.launch(runtime) else {
            setup.startFailed()
            return await broke("这台 Mac 上没有找到 \(profile.runtime.rawValue)")
        }
        do {
            let work = setup.directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let memory = CueMemoryView(try await setup.store.cueMemory())
            let config = CueBrainConfig(
                runtime: runtime, executable: launch.executable, model: profile.model, effort: profile.effort?.known,
                systemPrompt: CuePrompt.system(name: profile.name, memory: memory, agents: launch.agents), workingDirectory: work,
                mcp: [setup.helper.path, "mcp"],
                environment: ["CUEPAD_LIBRARY_DIR": setup.library.path, "PI_CODING_AGENT_DIR": setup.piAgentDirectory.path, "PATH": launch.path])
            let brain = try await config.startBrain()
            shifts += 1
            let id = shifts, input = input
            phase = .running(Shift(id: id, brain: brain, failures: failures))
            Task { for await event in brain.events { input.yield(.brain(id, event)) } }
            Self.log.notice("Cue 第 \(id) 个班次开始（\(runtime.rawValue, privacy: .public)）")
            if let wake { _ = try await wakeUp(wake, as: author) }
        } catch {
            setup.startFailed()
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
            await shift.brain.stop()()
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
            await say(.cue, "我起不来了：\(reason)\n你再发一条消息，我就再试一次。")
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
        if case .context = event {} else { Self.log.info("Cue 的大脑：\(String(describing: event).prefix(200), privacy: .private)") }
        switch event {
        case .turnStarted:
            if turn == nil { updateShift { $0.turn = Turn(author: .cue) } }  // 没有醒来就开始的一轮只能是插进来的你的话开的
        case .reply(let text):
            lastFailure = nil
            let author = turn?.author ?? .note
            if author == .note, await hasTold(since: turn?.startedAt ?? lastTurnEnd) { return }  // 已经对你说过了，动态那一行只是复述
            await say(author, text)
        case .context(let used, _):
            updateShift { $0.contextUsed = used }
        case .tool(let name, let arguments):
            updateShift { $0.turn?.tool = CueActivity.detail(tool: name, arguments: arguments) }
        case .toolDone:
            updateShift { $0.turn?.tool = nil }
        case .failed(let raw):
            updateShift { $0.turn?.failure = raw }
            let summary = PiErrorSummary(raw)
            // Cue 自己醒来的一轮第一次出错（会重试的那种）先不说：多是网络偶发，重试也失败了再告诉你；你在等的一轮立刻说
            if turn?.selfStarted != nil, setback == nil, Self.retryable(summary) { return }
            let line = summary.kind == .other ? raw : "\(summary.title)\n\(raw)"  // 认不出的错，摘要只是原文的首行
            guard line != lastFailure else { return }  // 同一个错一轮轮重复（如额度）只说一次
            lastFailure = line
            await say(.cue, "这一轮出错了：\(line)")
        case .turnFinished:
            guard let finished = turn else { return }
            updateShift {
                $0.turn = nil
                $0.failures = 0
            }
            lastTurnEnd = .now
            lastTurnAuthor = finished.author
            if let failure = finished.failure {
                if let woke = finished.selfStarted { await setBack(failure, retrying: woke, as: finished.author) }
            } else {
                setback = nil
                await advanceBaseline(finished.baseline)
            }
        case .exited(let reason):
            // 自己停的大脑不会走到这里（停之前已离开这个班次）：退出都是意外
            await broke(reason.map { "大脑退出了（\($0)）" } ?? "大脑退出了")
        }
    }

    /// 基线之后 Cue 跟进的事里的变化。
    private func changes() async throws -> [CueChange] {
        try await setup.store.cueChanges(since: progress.since, followed: progress.followed.map(Set.init))
    }

    /// 一轮做完、没出错：基线前移到醒来时，看板以此刻为准（这一轮里 Cue 自己建的、交还的不算变化）；
    /// 这一轮里会话的动静留到下次醒来，其余变化（多是 Cue 自己做的）不再报。
    private func advanceBaseline(_ baseline: (since: Date, followed: [UUID])?) async {
        if let baseline { (progress.since, progress.followed) = (baseline.since, baseline.followed) }
        do {
            let sessions: Set<CueChange.Kind> = [.settled, .waitingForUser, .failed, .youSpoke]
            progress.since = try await changes().filter { sessions.contains($0.kind) }.map(\.at).min()?.addingTimeInterval(-0.001) ?? .now
            progress.followed = try await setup.store.cueBoard().map(\.task.id)
        } catch {
            Self.log.error("Cue 读变化失败：\(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    /// Cue 自己醒来的一轮出错：第一次出错（且不是额度、登录）隔一会儿再醒一次，否则等新变化。
    private func setBack(_ failure: String, retrying woke: (wake: CueWake, extra: String?), as author: CueAuthor) async {
        let latest = try? await changes().map(\.at).max()
        let retry = setback == nil && Self.retryable(PiErrorSummary(failure))
        setback = Setback(
            latest: latest, retryAt: retry ? .now + setup.timing.retryWake.seconds : nil, wake: woke.wake, extra: woke.extra, author: author)
    }

    // MARK: 对账

    private func reconcile() async {
        timer?.cancel()
        timer = nil
        do {
            let store = setup.store, now = Date.now
            let pending = try await store.cueMessagesToDeliver().filter(\.wakesCue)
            if !pending.isEmpty {
                if case .stuck = phase { await startShift() }
                guard let shift else { return }
                let ids = pending.map(\.id)
                let said = pending.map { $0.author == .known(.you) ? $0.text : Self.answerLine($0) }.joined(separator: "\n\n")
                if shift.turn != nil {
                    do {
                        try await shift.brain.send(said)
                    } catch {
                        return await broke("发不进去：\(error.localizedDescription)")
                    }
                    updateShift {
                        $0.turn?.author = .cue
                        $0.turn?.delivered += ids
                    }
                    try await markDelivered(ids)
                } else {
                    _ = try await wakeUp(.message, said: said, delivering: ids)
                }
                return
            }
            guard let shift, shift.turn == nil else { return }

            let messages = try await store.cueMessages(limit: 50)
            if let handoff = messages.last(where: { $0.author == .known(.handoff) && $0.createdAt > shift.startedAt }) {
                await shift.brain.stop()()
                // 换新后的第一轮接着写下交接的那一轮：那一轮是你发起的，回复照样给你看
                await startShift(wake: .renewed(handoff: handoff.text), author: lastTurnAuthor)
                return
            }

            if progress.greeted != setup.profile.enabledAt {
                progress.greeted = setup.profile.enabledAt
                _ = try await wakeUp(.enabled)
                return
            }

            let due = try await store.dueCueReminders(at: now)
            if !due.isEmpty {
                var lines: [CueIndexedLine] = []
                for line in due { if let index = try await store.cueLineIndex(line.id) { lines.append(CueIndexedLine(index: index, line: line)) } }
                guard try await wakeUp(.reminder(lines)) else { return }
                for line in due { try await store.clearCueReminder(line.id) }
                return
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueReminder(after: now) { deadlines.append(next) }

            let timing = setup.timing
            let lastSpoke = messages.last { $0.author == .known(.you) }?.createdAt
            let changes = try await changes()
            let latest = changes.map(\.at).max()
            // 出错之后：有新变化就是新事件，照常；没有就等重试的时刻，过了这一次就只等新变化
            if let held = setback {
                if let latest, latest > held.latest ?? .distantPast {
                    setback = nil
                } else if let retryAt = held.retryAt, now >= retryAt {
                    setback?.retryAt = nil
                    window = nil
                    return _ = try await wakeUp(held.wake, as: held.author, extra: held.extra)
                } else {
                    return schedule([deadlines.min(), held.retryAt].compactMap { $0 }.min())
                }
            }
            if let latest {
                var current = window ?? (first: now, last: now, latest: latest)
                if latest > current.latest { (current.last, current.latest) = (now, latest) }
                window = current
                let settled = min(current.last + timing.quiet.seconds, current.first + timing.quietLimit.seconds)
                let blocked = changes.contains { $0.kind == .waitingForUser }
                let ready = blocked ? now : max(settled, lastSpoke.map { $0 + timing.talking.seconds } ?? .distantPast)
                if now >= ready {
                    window = nil
                    return _ = try await wakeUp(.sessionActivity)
                }
                deadlines.append(ready)
            } else {
                window = nil
            }

            let idleSince = lastSpoke ?? setup.profile.enabledAt ?? shift.startedAt
            if try await store.cueBoard().isEmpty, let due = patrolDue(idleSince: idleSince, now: now) {
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

    /// 发一个信封让 Cue 醒来，这一轮的回复写成谁的按醒来原因定（`author(of:)`）；`delivering` 是随信封交出去的你的消息与回答，
    /// 连同信封变化里你关掉的提问，发出去就记下送达。发不进去时按大脑出了问题处理，返回 false。
    private func wakeUp(
        _ wake: CueWake, as chosen: CueAuthor? = nil, said: String? = nil, delivering: [UUID] = [], extra: String? = nil
    ) async throws -> Bool {
        guard let shift else { return false }
        let author = chosen ?? Self.author(of: wake)
        let store = setup.store, now = Date.now
        let board = try await store.cueBoard()
        let dismissed = try await store.cueMessagesToDeliver().filter { !$0.wakesCue }
        let delivering = delivering + dismissed.map(\.id)
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: now, contextUsed: shift.contextUsed, renewAt: Self.renewAt, since: progress.since, projects: try await store.cueProjects(),
            changes: try await changes(), dismissed: dismissed, board: board, waiting: try await store.cueMessagesWaitingForYou(), wake: wake, said: nil))
        var parts = [envelope]
        if let used = shift.contextUsed, used >= Self.renewAt { parts.append("上下文到了换新线：先用 memory renew 写交接备忘，再结束这一轮。") }
        if let extra { parts.append(extra) }
        if let said { parts.append(said) }
        Self.log.notice("Cue 醒来：\(String(describing: wake).prefix(60), privacy: .public)，回复写成 \(author.rawValue, privacy: .public)")
        do {
            try await shift.brain.send(parts.joined(separator: "\n"))
        } catch {
            await broke("发不进去：\(error.localizedDescription)")  // 这一轮还没开，交出去的话也还没记送达
            return false
        }
        updateShift {
            $0.turn = Turn(
                author: author, selfStarted: wake == .message ? nil : (wake, extra), delivered: delivering, baseline: (now, board.map(\.task.id)))
        }
        save()
        try await markDelivered(delivering)
        return true
    }

    /// 记下送达并立即上传（不等上传完就接着对账）。
    private func markDelivered(_ ids: [UUID]) async throws {
        try await setup.store.markCueMessagesDelivered(ids)
        guard !ids.isEmpty else { return }
        let upload = setup.upload
        Task { await upload(ids) }
    }

    /// Cue 在 `since` 之后写过给你的消息（tell）。
    private func hasTold(since: Date) async -> Bool {
        do {
            return try await setup.store.cueMessages(limit: 50).contains { $0.author == .known(.cue) && $0.createdAt >= since }
        } catch {
            Self.log.error("Cue 读对话失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func say(_ author: CueAuthor, _ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await setup.store.addCueMessage(author, text: text)
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

    /// 这一轮的回复写成谁的：你发来消息、刚启用（你正看着屏幕）写成 cue；其余 Cue 自己醒来的写成 note（换新由调用方按写下交接的那一轮定）。
    private static func author(of wake: CueWake) -> CueAuthor {
        switch wake {
        case .message, .enabled: .cue
        case .sessionActivity, .idle, .reminder, .renewed: .note
        }
    }

    /// 重试可能好的错：额度、登录类的不算。
    private static func retryable(_ summary: PiErrorSummary) -> Bool { summary.kind != .quota && summary.kind != .authentication }

    private static func answerLine(_ message: CueMessage) -> String {
        let question = CueFormat.plainText(message.text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "你回答了「\(question)」：\(message.answer ?? "")"
    }

    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}

extension Duration {
    nonisolated var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}
#endif
