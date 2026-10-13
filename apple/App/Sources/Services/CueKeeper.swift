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
    /// 这些钟点（本地）不推通知。
    var quietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]
}

/// 一个"在这台 Mac 上值班"的时段：Cue 住在这台 Mac 且已启用时由 `CueService` 起一个，设置变了或不再住这里时停掉。
/// 一个班次是一个大脑进程（`CueBrain`），系统提示在班次内不变；对话、跟进与"等你"都在库里，换班次、App 重启都不丢。
///
/// 对账：库一变（订阅，不轮询）、大脑有事件、定时器到点，都重新对一次账，按先后只做一件事：
/// 1. 你的消息与"等你"的回答：大脑空闲就发信封醒来，正忙就插进当前这一轮；写 `deliveredAt`（回答也记在那条"等你"上）。
/// 2. 这一轮还没完就等。
/// 3. 换新：本班次里出现了交接备忘（`memory renew`）就停掉大脑、起新班次，第一轮醒来带上交接。
///    刚启用（这一次启用还没醒过，含另一台 Mac 接管过来）：醒来看看你手上有哪些事。
/// 4. 提醒到点：醒来、清掉提醒。
/// 5. 跟进的事有变化：攒安静窗口再醒；你还在和 Cue 说话时先压着。
/// 6. 空闲巡视：没在跟进任何事、你很久没说话、本地 9–23 点，每段空闲最多一次、每天最多 3 次。
/// 7. 记忆有待合并的块且空闲够久：醒来附上合并提示（同一块一个班次只请一次）。
///
/// 一轮是谁发起的决定回复写成什么：你发起的（含插进来的话）写成 `cue`，Cue 自己醒来的写成 `note`（折成灰色一行、不推送）。
/// 上下文用到 `renewAt` 后，下一次醒来的信封里提示先写交接。大脑意外退出或起不来按 `CueTiming.restarts` 退避重试，
/// 连续失败超过次数写一条 Cue 消息、停在"起不来"，等你的下一条消息再试。
final class CueKeeper {
    /// 上下文用到这么多 token 就请 Cue 换新。
    nonisolated static let renewAt = 60_000
    nonisolated static let patrolHours = 9..<23
    nonisolated static let patrolsPerDay = 3

    struct Setup {
        var store: CueStore
        var profile: CueProfile
        var scan: @Sendable () async -> CueRuntimeScan
        /// `cuepad` 命令行（MCP 服务）
        var helper: URL
        /// App 正在用的资料库目录：MCP 服务经 `CUEPAD_LIBRARY_DIR` 打开同一个库
        var library: URL
        var piAgentDirectory: URL
        /// Cue 自己的目录：`work` 是大脑的工作目录（空的），`keeper.json` 是跨班次的对账进度
        var directory: URL
        var timing: CueTiming
    }

    /// 跨班次、跨 App 重启的对账进度（本机，只给这台 Mac 的管理器用）。
    private nonisolated struct Progress: Codable {
        /// 上次醒来的时刻：变化从这之后算
        var since = Date.now
        /// 上次醒来时看板上的任务；nil 是还没醒过（不比跟进集合）
        var followed: [UUID]?
        var patrolDay: String?
        var patrols = 0
        /// 巡视过的那段空闲（从你上次说话起）
        var patrolledIdle: Date?
        /// 已为哪一次启用（`CueProfile.enabledAt`）醒来过
        var greeted: Date?
    }

    private nonisolated enum Input: Sendable {
        case kick, retry, stop
        case brain(Int, CueBrainEvent)
    }

    /// 触发对账的读数：变了就对一次账（内容不用，对账自己读）。
    private nonisolated struct Signal: Equatable, Sendable {
        var messages: [CueMessage]
        var board: [CueBoardItem]
        var reminder: Date?
    }

    private nonisolated static let log = Logger(subsystem: "com.sugeh.cuepad", category: "cue")

    private let setup: Setup
    private let onState: (CueState) -> Void
    private let inputs: AsyncStream<Input>
    private let input: AsyncStream<Input>.Continuation
    private var progress: Progress

    private(set) var brain: (any CueBrain)?
    private var shift = 0
    private var shiftStart = Date.distantPast
    /// 这一轮的回复写成谁的；nil 是没有在跑的一轮
    private var turn: CueAuthor?
    private var contextUsed: Int?
    private var lastTurnEnd = Date.now
    private var failures = 0
    private var restarting = false
    private var stuck: String?
    private var lastFailure: String?
    private var mergesTried: Set<[Int]> = []
    private var window: (first: Date, last: Date, latest: Date)?
    private var timer: Task<Void, Never>?

    init(_ setup: Setup, onState: @escaping (CueState) -> Void) {
        self.setup = setup
        self.onState = onState
        (inputs, input) = AsyncStream.makeStream()
        progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: setup.directory.appending(path: "keeper.json")))) ?? Progress()
    }

    var state: CueState {
        if let stuck { .failed(stuck) } else if turn != nil { .thinking } else { .idle }
    }

    /// 值班到 `stop()` 或任务取消，返回前停掉大脑。
    func run() async {
        let (store, input) = (setup.store, input)
        await withDiscardingTaskGroup { group in
            group.addTask {
                do {
                    for try await _ in store.observe({ store in
                        Signal(messages: try store.cueMessages(limit: 50), board: try store.cueBoard(), reminder: try store.nextCueReminder(after: .distantPast))
                    }) { input.yield(.kick) }
                } catch {
                    Self.log.error("Cue 订阅资料库失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            await startShift()
            onState(state)
            loop: for await next in inputs {
                switch next {
                case .stop: break loop
                case .kick: break
                case .retry: if brain == nil, stuck == nil { await startShift() }
                case .brain(let id, let event): if id == shift { await handle(event) }
                }
                await reconcile()
                onState(state)
            }
            group.cancelAll()
        }
        timer?.cancel()
        await brain?.stop()
        brain = nil
    }

    func stop() { input.yield(.stop) }

    // MARK: 班次

    private func startShift(wake: CueWake? = nil) async {
        restarting = false
        let profile = setup.profile
        let scan = await setup.scan()
        guard let runtime = profile.runtime.known, let option = scan.option(runtime) else {
            return await broke("这台 Mac 上的 \(profile.runtime.rawValue) 没装或没登录")
        }
        do {
            let work = setup.directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let memory = CueMemoryView(try await setup.store.cueMemory())
            let config = CueBrainConfig(
                runtime: runtime, executable: option.executable, model: profile.model, effort: profile.effort?.known,
                systemPrompt: CuePrompt.system(name: profile.name, memory: memory, agents: scan.agents), workingDirectory: work,
                mcp: [setup.helper.path, "mcp"],
                environment: ["CUEPAD_LIBRARY_DIR": setup.library.path, "PI_CODING_AGENT_DIR": setup.piAgentDirectory.path, "PATH": scan.path])
            let brain = try await config.startBrain()
            shift += 1
            let id = shift, input = input
            self.brain = brain
            shiftStart = .now
            contextUsed = nil
            turn = nil
            mergesTried = []
            Task { for await event in brain.events { input.yield(.brain(id, event)) } }
            Self.log.notice("Cue 第 \(id) 个班次开始（\(runtime.rawValue, privacy: .public)）")
            if let wake { try await wakeUp(wake, as: .note) }
        } catch {
            await broke(error.localizedDescription)
        }
    }

    /// 大脑起不来或意外退出：退避重试，都失败就停在"起不来"。
    private func broke(_ reason: String) async {
        Self.log.error("Cue 的大脑出了问题：\(reason, privacy: .public)")
        if let brain { await brain.stop() }
        brain = nil
        turn = nil
        failures += 1
        guard failures <= setup.timing.restarts.count else {
            stuck = reason
            restarting = false
            await say(.cue, "我起不来了：\(reason)\n你再发一条消息，我就再试一次。")
            return
        }
        restarting = true
        let delay = setup.timing.restarts[failures - 1], input = input
        Task {
            try? await Task.sleep(for: delay)
            input.yield(.retry)
        }
    }

    private func handle(_ event: CueBrainEvent) async {
        switch event {
        case .turnStarted:
            if turn == nil { turn = .cue }  // 没有醒来就开始的一轮只能是插进来的你的话开的
        case .reply(let text):
            await say(turn ?? .note, text)
            lastFailure = nil
        case .context(let used, _):
            contextUsed = used
        case .failed(let raw):
            let summary = PiErrorSummary(raw)
            let line = summary.title == raw ? raw : "\(summary.title)\n\(raw)"
            guard line != lastFailure else { return }  // 同一个错一轮轮重复（如额度）只说一次
            lastFailure = line
            await say(.cue, "这一轮出错了：\(line)")
        case .turnFinished:
            turn = nil
            lastTurnEnd = .now
            failures = 0
            await absorbOwnChanges()
        case .exited(let reason):
            brain = nil
            turn = nil
            if let reason { await broke("大脑退出了（\(reason)）") }
        }
    }

    /// 一轮做完：看板以此刻为准（这一轮里 Cue 自己建的、交还的不算变化）；这一轮里会话的动静留到下次醒来，其余变化（多是 Cue 自己做的）不再报。
    private func absorbOwnChanges() async {
        do {
            let changes = try await setup.store.cueChanges(since: progress.since, followed: progress.followed.map(Set.init))
            let sessions: Set<CueChange.Kind> = [.settled, .waitingForUser, .failed, .youSpoke]
            progress.since = changes.filter { sessions.contains($0.kind) }.map(\.at).min()?.addingTimeInterval(-0.001) ?? .now
            progress.followed = try await setup.store.cueBoard().map(\.task.id)
            save()
        } catch {
            Self.log.error("Cue 读变化失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 对账

    private func reconcile() async {
        timer?.cancel()
        timer = nil
        guard !restarting else { return }
        do {
            let store = setup.store, now = Date.now
            let messages = try await store.cueMessages(limit: 50)
            let yours = try await store.undeliveredCueMessages()
            let answers = messages.filter { $0.author == .known(.cue) && $0.choices != nil && $0.answeredAt != nil && $0.deliveredAt == nil }
            if !yours.isEmpty || !answers.isEmpty {
                if stuck != nil {
                    stuck = nil
                    failures = 0
                    await startShift()
                }
                guard let brain else { return }
                let said = (yours.map(\.text) + answers.map(Self.answerLine)).joined(separator: "\n\n")
                if turn != nil {
                    try await brain.send(said)
                    turn = .cue
                } else {
                    try await wakeUp(.message, as: .cue, said: said)
                }
                try await store.markCueMessagesDelivered((yours + answers).map(\.id))
                return
            }
            guard let brain, turn == nil, stuck == nil else { return }

            if let handoff = messages.last(where: { $0.author == .known(.handoff) && $0.createdAt > shiftStart }) {
                await brain.stop()
                self.brain = nil
                await startShift(wake: .renewed(handoff: handoff.text))
                return
            }

            if progress.greeted != setup.profile.enabledAt {
                progress.greeted = setup.profile.enabledAt
                return try await wakeUp(.enabled, as: .note)
            }

            let due = try await store.dueCueReminders(at: now)
            if !due.isEmpty {
                var lines: [CueIndexedLine] = []
                for line in due { if let index = try await store.cueLineIndex(line.id) { lines.append(CueIndexedLine(index: index, line: line)) } }
                try await wakeUp(.reminder(lines), as: .note)
                for line in due { try await store.clearCueReminder(line.id) }
                return
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueReminder(after: now) { deadlines.append(next) }

            let timing = setup.timing
            let lastSpoke = messages.last { $0.author == .known(.you) }?.createdAt
            let changes = try await store.cueChanges(since: progress.since, followed: progress.followed.map(Set.init))
            if let latest = changes.map(\.at).max() {
                var current = window ?? (first: now, last: now, latest: latest)
                if latest > current.latest { (current.last, current.latest) = (now, latest) }
                window = current
                let settled = min(current.last + timing.quiet.seconds, current.first + timing.quietLimit.seconds)
                let ready = max(settled, lastSpoke.map { $0 + timing.talking.seconds } ?? .distantPast)
                if now >= ready {
                    window = nil
                    return try await wakeUp(.sessionActivity, as: .note)
                }
                deadlines.append(ready)
            } else {
                window = nil
            }

            if try await store.cueBoard().isEmpty, let due = patrolDue(lastSpoke: lastSpoke, now: now) {
                if due <= now {
                    let today = Self.day(now)
                    progress.patrols = (progress.patrolDay == today ? progress.patrols : 0) + 1
                    progress.patrolDay = today
                    progress.patrolledIdle = lastSpoke ?? setup.profile.enabledAt
                    return try await wakeUp(.idle, as: .note)
                }
                deadlines.append(due)
            }

            let memory = CueMemoryView(try await store.cueMemory())
            if let merge = memory.merges.first(where: { !mergesTried.contains([$0.lo, $0.hi]) }) {
                let ready = lastTurnEnd + timing.mergeAfter.seconds
                if now >= ready {
                    mergesTried.insert([merge.lo, merge.hi])
                    return try await wakeUp(.idle, as: .note, extra: CueMemoryView.mergePrompt(merge))
                }
                deadlines.append(ready)
            }
            schedule(deadlines.min())
        } catch {
            Self.log.error("Cue 对账失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 什么时候可以巡视；这段空闲巡视过了、今天次数用完为 nil。
    private func patrolDue(lastSpoke: Date?, now: Date) -> Date? {
        let idleSince = lastSpoke ?? setup.profile.enabledAt ?? shiftStart
        let today = Self.day(now)
        let used = progress.patrolDay == today ? progress.patrols : 0
        guard progress.patrolledIdle != idleSince else { return nil }
        guard used < Self.patrolsPerDay else { return Calendar.current.nextDate(after: now, matching: DateComponents(hour: Self.patrolHours.lowerBound), matchingPolicy: .nextTime) }
        let earliest = max(now, idleSince + setup.timing.patrolAfter.seconds)
        let hour = Calendar.current.component(.hour, from: earliest)
        if Self.patrolHours.contains(hour) { return earliest }
        return Calendar.current.nextDate(after: earliest, matching: DateComponents(hour: Self.patrolHours.lowerBound), matchingPolicy: .nextTime)
    }

    /// 发一个信封让 Cue 醒来，这一轮的回复写成 `author` 的。
    private func wakeUp(_ wake: CueWake, as author: CueAuthor, said: String? = nil, extra: String? = nil) async throws {
        guard let brain else { return }
        let store = setup.store, now = Date.now
        let board = try await store.cueBoard()
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: now, contextUsed: contextUsed, renewAt: Self.renewAt, since: progress.since,
            changes: try await store.cueChanges(since: progress.since, followed: progress.followed.map(Set.init)),
            board: board, waiting: try await store.cueMessagesWaitingForYou(), wake: wake, said: nil))
        var parts = [envelope]
        if let used = contextUsed, used >= Self.renewAt { parts.append("上下文到了换新线：先用 memory renew 写交接备忘，再结束这一轮。") }
        if let extra { parts.append(extra) }
        if let said { parts.append(said) }
        turn = author
        do {
            try await brain.send(parts.joined(separator: "\n"))
        } catch {
            turn = nil
            await broke("发不进去：\(error.localizedDescription)")
            return
        }
        progress.since = now
        progress.followed = board.map(\.task.id)
        save()
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
