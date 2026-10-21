#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

// 醒来与写回：发信封、读提醒、记送达、转图、写回复与消息、排定时器、存进度。
extension CueKeeper {
    /// 发一个信封让 Cue 醒来，这一轮的回复写成谁的按醒来原因定（`author(of:)`）；`said`、`images`、`delivering` 是随信封交出去的你的消息与回答，
    /// 发出去就记下送达。发不进去时按大脑出了问题处理，返回 false。
    func wakeUp(
        _ wake: CueWake, as chosen: CueAuthor? = nil, said: String? = nil, images: [PiImage] = [], delivering: [UUID] = [], extra: String? = nil
    ) async throws -> Bool {
        guard let shift else { return false }
        let author = chosen ?? Self.author(of: wake)
        let store = self.store, now = Date.now
        let mark = try await store.lastWrite()
        let board = try await store.cueBoard()
        var resume: CueResume?
        if !shift.resumed {
            resume = try await store.cueResume(limit: CueEnvelope.resumeMessages)
            resume?.messages.removeAll { delivering.contains($0.id) }
        }
        let changes = try await self.changes(at: now)
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: now, contextUsed: shift.context?.used, projects: try await store.projects(),
            changes: changes.due, board: board, waiting: try await store.cueMessagesWaitingForYou(), left: try await store.cueState()?.left ?? [],
            wake: wake, reminders: try await reminders(of: wake), resume: resume))
        var parts = [envelope]
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
            $0.resumed = true
            $0.turn = turn
        }
        save()
        try await markDelivered(delivering)
        return true
    }

    /// 提醒到点的一轮要列给它的那几条记忆（带序号）；别的原因醒来没有。
    private func reminders(of wake: CueWake) async throws -> [CueIndexedLine] {
        guard case .reminder(let ids) = wake else { return [] }
        return try await store.cueLines(ids)
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
            await say(.cue, "我现在用的模型看不了图，你发的图我看不到；要我看图，换个能看图的模型。图我还能原样转给会话。")
            return []
        }
        do {
            return try contents.flatMap { try $0.piImages(from: store.files) }
        } catch {
            await say(.cue, "你发的图没能交给我：\(error.localizedDescription)")
            return []
        }
    }

    /// 这一轮写给你的话（回复、回答你的一轮出错）：提不提示你、一轮只响一次都在 `CueStore.replyCueRound`。
    func reply(_ text: String, in turn: Turn) async {
        do {
            try await store.replyCueRound(startedAt: turn.round.startedAt, reply: text, as: turn.author, answersYou: turn.answersYou)
        } catch {
            Self.log.error("Cue 这一轮的话没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// `urgent`：要提示你（`CueMessage.urgent`）。
    func say(_ author: CueAuthor, _ text: String, urgent: Bool = false) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await store.addCueMessage(author, text: text, urgent: urgent)
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

    /// 这一轮的回复写成谁的：你发来消息、刚启用写成 cue；其余写成 note（换新由调用方按写下交接的那一轮定）。
    static func author(of wake: CueWake) -> CueAuthor {
        switch wake {
        case .message, .enabled: .cue
        case .sessionActivity, .idle, .tidy, .reminder, .renewed, .settingsChanged: .note
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
