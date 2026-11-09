import CueStore
import SwiftUI

/// 对话排成的格子与刻度滑条的刻度在读的时候一起推好（不在主线程，滚动时页面重算也不再推一遍）。
nonisolated struct CueThread: Equatable, Sendable {
    /// 最近的对话，从早到晚；前面另带上早于它问、在它这段时间里答了的提问（`CueStore.cueQuestionsAnswered`）：
    /// 你的回答在读到的范围里，它引用的那条提问也要在，点引用才回得去。
    let messages: [CueMessage]
    let waiting: [CueWait]
    let shots: [UUID: [CueShown]]
    let rows: [Row]
    let joined: Set<UUID>
    let stamps: [UUID: Date]
    let marks: [ChatMark]
    /// 还没读的 Cue 的话（Kit 的 `cueUnread` 是唯一的规则）。
    let unread: Set<UUID>

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    init(
        messages: [CueMessage], waiting: [CueWait], shots: [UUID: [CueShown]],
        unread: Set<UUID>, lines: [UUID: CueMemoryLine]
    ) {
        self.messages = messages
        self.waiting = waiting
        self.shots = shots
        self.unread = unread
        let rows = Self.rows(messages, waiting: Set(waiting.compactMap(\.message?.id)), shots: shots, lines: lines)
        self.rows = rows
        let stamps = Self.stamps(rows)
        self.stamps = stamps
        joined = Set(zip(rows, rows.dropFirst()).compactMap { above, row in
            row.speaker != nil && row.speaker == above.speaker && stamps[row.id] == nil ? row.id : nil
        })
        marks = ChatMark.enough(rows.compactMap { row in
            switch row {
            case .you(let message): ChatMark(id: message.id, kind: .said, preview: ChatMark.firstLine(message.text))
            case .answer(let question, _): ChatMark(id: row.id, kind: .said, preview: ChatMark.firstLine(question.answer ?? ""))
            case .cue, .result, .notes, .process: nil
            }
        })
    }

    static func read(from store: isolated CueStore) throws -> CueThread {
        let recent = try store.cueMessages(limit: limit)
        let messages = try store.cueQuestionsAnswered(outside: recent) + recent
        let waits = try CueWait.read(try store.cueWaiting(), from: store)
        let waiting = waits.compactMap(\.message)
        let pointed = (messages + waiting).filter { !$0.shots.isEmpty }
        let previews = try store.previews(Set(pointed.flatMap { $0.shots.map(\.preview) }))
        var shots: [UUID: [CueShown]] = [:]
        for message in pointed {
            let shown = message.shots.compactMap { shot in
                previews[shot.preview].map { CueShown(preview: $0, look: shot.look) }
            }
            if !shown.isEmpty { shots[message.id] = shown }
        }
        let fired = messages.flatMap { message -> [UUID] in if case .schedule(let fires)? = message.wake { fires.map(\.line) } else { [] } }
        return CueThread(
            messages: messages, waiting: waits, shots: shots, unread: Set(try store.cueUnread()),
            lines: Dictionary(try store.cueLines(fired).map { ($0.id, $0) }) { first, _ in first })
    }

    /// 还在等你的提问不在对话里，都在输入框上方的拍板卡里（同一问同屏一处），结束了回到 Cue 的一句；你答了的，答的那一刻另有一格你的回答（`answer`）。
    enum Row: Identifiable, Equatable, Sendable {
        case you(CueMessage)
        /// 问的那句紧挨在上面时不带引用（`quoted` 为 false，问句同屏只留一份），隔开了才在字上面引一行它问的是什么。
        case answer(CueMessage, quoted: Bool)
        case cue(CueMessage, task: UUID?)
        case result(CueMessage, task: UUID)
        case notes([CueNoteRound])
        case process(CueMessage, touches: [CueActivity.Touch])

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.id
            case .answer(let question, _): Self.answerID(of: question.id)
            case .notes(let rounds): rounds[0].id
            }
        }

        var date: Date {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.createdAt
            case .answer(let question, _): question.answeredAt ?? question.createdAt
            case .notes(let rounds): rounds[0].date
            }
        }

        static func answerID(of question: UUID) -> UUID {
            var bytes = question.uuid
            bytes.0 ^= 0xA5
            return UUID(uuid: bytes)
        }

        var taskID: UUID? {
            switch self {
            case .cue(_, let task): task
            case .result(_, let task): task
            case .you, .answer, .notes, .process: nil
            }
        }

        var speaker: HorizontalEdge? {
            switch self {
            case .you, .answer: .trailing
            case .cue: .leading
            case .result, .notes, .process: nil
            }
        }
    }

    private static func stamps(_ rows: [Row]) -> [UUID: Date] {
        var stamps: [UUID: Date] = [:]
        var previous: Date?
        let calendar = Calendar.current
        for row in rows {
            defer { previous = row.date }
            guard let previous else {
                stamps[row.id] = row.date
                continue
            }
            if row.date.timeIntervalSince(previous) >= ChatTime.gap || !calendar.isDate(row.date, inSameDayAs: previous) { stamps[row.id] = row.date }
        }
        return stamps
    }

    /// 回答按答的那一刻插进对话，与会话里的作答、预览卡同一条规则（`PiChat.entries`）。
    /// 结果卡只挂点名的那几张图，这件活发到手机的其余文件在它的会话里。
    private static func rows(
        _ messages: [CueMessage], waiting: Set<UUID>, shots: [UUID: [CueShown]], lines: [UUID: CueMemoryLine]
    ) -> [Row] {
        var answers = messages.enumerated().filter { $0.element.answer != nil && $0.element.answeredAt != nil }
            .sorted { ($0.element.answeredAt!, $0.offset) < ($1.element.answeredAt!, $1.offset) }.map(\.element)[...]
        var shown = Set<UUID>()
        var rows: [Row] = []
        func placeAnswers(before time: Date?) {
            while let next = answers.first, time.map({ next.answeredAt! < $0 }) ?? true {
                let follows = if case .cue(let asked, _) = rows.last { asked.id == next.id } else { false }
                rows.append(.answer(next, quoted: !follows))
                answers.removeFirst()
            }
        }
        for message in messages {
            placeAnswers(before: message.createdAt)
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if waiting.contains(message.id) { continue }
                if message.choices == nil, shots[message.id] != nil, let id = message.taskID {
                    shown.insert(id)
                    rows.append(.result(message, task: id))
                    continue
                }
                let task = message.taskID.flatMap { shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, task: task))
            case .note:
                // 一轮的经过（为什么醒、做了什么）；有正文的是旧版本写下的动态，不再显示
                guard message.text.isEmpty else { continue }
                var group: [CueNoteRound] = []
                if case .notes(let open) = rows.last, let last = open.last, CueNoteRound.continues(last, at: message.createdAt) {
                    group = open
                    rows.removeLast()
                }
                group.append(CueNoteRound(row: message, lines: lines))
                rows.append(.notes(group))
            case .round:
                let touches = CueActivity.touches(message.tools)
                if !touches.isEmpty { rows.append(.process(message, touches: touches)) }
            // 认不出的（旧版本写下的交接备忘、更新版本的新种类）不列
            case nil: break
            }
        }
        placeAnswers(before: nil)
        // 旧版本写下的经过（没有醒来原因）又没说话的那一节什么都不剩
        return rows.compactMap { row in
            guard case .notes(let rounds) = row else { return row }
            let shown = rounds.filter { !$0.isEmpty }
            return shown.isEmpty ? nil : .notes(shown)
        }
    }
}

nonisolated struct CueShown: Identifiable, Equatable, Sendable {
    let preview: PiPreview
    let look: String
    var id: UUID { preview.id }
}

