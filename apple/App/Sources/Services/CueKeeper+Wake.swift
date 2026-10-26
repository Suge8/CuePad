#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation

extension CueKeeper {
    /// 发一个信封让 Cue 醒来，这一轮的回复写成谁的按醒来原因定（`author(of:)`）；`said`、`images`、`delivering` 是随信封交出去的你的消息与回答，
    /// 发出去就记下送达。发不进去时按大脑出了问题处理，返回 false。
    func wakeUp(
        _ wake: CueWake, as chosen: CueAuthor? = nil, said: String? = nil, images: [PiImage] = [], delivering: [UUID] = []
    ) async throws -> Bool {
        guard let shift else { return false }
        let author = chosen ?? Self.author(of: wake)
        let store = self.store, now = Date.now
        let mark = try await store.lastWrite()
        let board = try await store.cueBoard()
        let changes = try await self.changes(at: now)
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: setup.timing.clock(), projects: try await store.projects(),
            changes: changes.due, board: board, waiting: try await store.cueMessagesWaitingForYou(), left: try await store.cueState()?.left ?? [],
            wake: wake, fired: try await fired(of: wake), schedules: try await store.cueScheduleLines(), language: CueInterface.current.writing(after: said)))
        var parts = [envelope]
        if !shift.primed || renewDue(shift, now: now) {
            if shift.primed {
                do {
                    try await shift.brain.newSession()
                } catch {
                    await broke(ShownText("开不了新会话：\(ShownText(error).embedded)"))
                    return false
                }
                Self.log.notice("Cue 换新：开了新会话")
                updateShift {
                    $0.context = nil
                    $0.lastRequest = nil
                }
            }
            // 还没交给它的你的话不进对话视图：它们这次随信封交出去（`CueView` 只列已送达的）
            let views = [CueMemoryView(try await store.cueMemory()).viewText, CueView.render(try await store.cueMessages(limit: CueView.fetched))]
            parts.insert(contentsOf: views.compactMap { $0 }, at: 0)
        }
        if let said { parts.append(said) }
        Self.log.notice("Cue 醒来：\(String(describing: wake).prefix(60), privacy: .public)，回复写成 \(author.rawValue, privacy: .public)")
        let sent = parts.joined(separator: "\n")
        do {
            try await shift.brain.send(sent, images: images)
        } catch {
            await broke(ShownText("发不进去：\(ShownText(error).embedded)"))  // 这一轮还没开，交出去的话也还没记送达
            return false
        }
        var turn = Turn(
            author: author, round: beginRound(wake, sent: [sent], at: now), selfStarted: wake == .message ? nil : wake, delivered: delivering,
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

    /// 定时到点的一轮要列给它的那几条定时（带序号、本该几点与挂着的任务）；别的原因醒来没有。
    private func fired(of wake: CueWake) async throws -> [CueEnvelope.Fired] {
        guard case .schedule(let fires) = wake else { return [] }
        let lines = try await store.cueLines(fires.map(\.line))
        var fired: [CueEnvelope.Fired] = []
        for fire in fires {
            guard let line = lines.first(where: { $0.line.id == fire.line }) else { continue }
            let task = if let id = line.line.task { try await store.card(id) } else { Card?.none }
            fired.append(CueEnvelope.Fired(line: line, due: fire.due, task: task))
        }
        return fired
    }

    /// 这次醒来要先开新会话（换新，唯一规则）：上下文到了换新线，或距上一次模型请求超过提示缓存的时长（缓存已过期，接着用要把整段原价重写；
    /// 换新只写固定前缀与视图，从不更贵）。还没请求过模型的会话不换。
    func renewDue(_ shift: Shift, now: Date) -> Bool {
        guard let used = shift.context?.used, let last = shift.lastRequest else { return false }
        return used >= setup.timing.renewAt || now.timeIntervalSince(last) > setup.timing.cacheLifetime.seconds
    }

    /// 记下送达并立即上传（不等上传完就接着对账）。
    func markDelivered(_ ids: [UUID]) async throws {
        try await store.markCueMessagesDelivered(ids)
        guard !ids.isEmpty else { return }
        let upload = setup.upload
        Task { await upload(ids) }
    }

    /// 你的消息里的图，按发给会话的同一个转换取出、交给大脑；文字里的图片引用照留（Cue 转给会话时原样写进去）。
    /// 模型看不了图、或图不在这台 Mac 上，不交图并对你说一声，不悄悄丢掉。
    func images(in pending: [CueMessage], for brain: any CueBrain) async -> [PiImage] {
        let contents = pending.filter { $0.author == .known(.you) }.map { SendContent(stored: $0.text) }.filter(\.hasImages)
        guard !contents.isEmpty else { return [] }
        guard brain.seesImages else {
            await say(.cue, ShownText("我现在用的模型看不了图，你发的图我看不到；要我看图，换个能看图的模型。图我还能原样转给会话。"))
            return []
        }
        do {
            return try contents.flatMap { try $0.piImages(from: store.files) }
        } catch {
            await say(.cue, ShownText("你发的图没能交给我：\(ShownText(error).embedded)"))
            return []
        }
    }

    /// 这一轮写给你的话（回复、回答你的一轮出错）：提不提示你、一轮只响一次都在 `CueStore.replyCueRound`。
    func reply(_ text: ShownText, in turn: Turn) async {
        do {
            try await store.replyCueRound(startedAt: turn.round.startedAt, reply: text, as: turn.author, answersYou: turn.answersYou)
        } catch {
            Self.log.error("Cue 这一轮的话没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// `urgent`：要提示你（`CueMessage.urgent`）。
    func say(_ author: CueAuthor, _ text: ShownText, urgent: Bool = false) async {
        do {
            try await store.addCueMessage(author, shown: text, urgent: urgent)
        } catch {
            Self.log.error("Cue 的消息没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    func schedule(_ date: Date?) {
        guard let date else { return }
        let input = input, delay = max(0, date.timeIntervalSinceNow) + 0.05
        timer = Task {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            input.yield(.kick)
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: setup.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(progress).write(to: setup.directory.appending(path: "keeper.json"), options: .atomic)
        } catch {
            Self.log.error("Cue 的对账进度没能存下：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 这一轮的回复写成谁的：你发来消息、刚启用写成 cue；其余写成 note。
    static func author(of wake: CueWake) -> CueAuthor {
        switch wake {
        case .message, .enabled: .cue
        case .sessionActivity, .idle, .schedule: .note
        }
    }

    /// 重试可能好的错：额度、登录类的不算。
    static func retryable(_ summary: PiErrorSummary) -> Bool { summary.kind != .quota && summary.kind != .authentication }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}
#endif
