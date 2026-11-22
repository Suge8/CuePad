import CueStore
import SwiftUI

nonisolated struct CueThread: Equatable, Sendable {
    let messages: [CueMessage]
    let waiting: [CueWait]
    let shots: [UUID: [CueShown]]
    let rows: [Row]
    let joined: Set<UUID>
    let stamps: [UUID: Date]
    let marks: [ChatMark]
    let unread: Set<UUID>

    static let limit = 200

    init(
        messages: [CueMessage], waiting: [CueWait], shots: [UUID: [CueShown]],
        unread: Set<UUID>, lines: [UUID: CueMemoryLine]
    ) {
        self.messages = messages
        self.waiting = waiting
        self.shots = shots
        self.unread = unread
        let rows = Self.rows(messages, shots: shots, lines: lines)
        self.rows = rows
        let stamps = Self.stamps(rows)
        self.stamps = stamps
        joined = Set(zip(rows, rows.dropFirst()).compactMap { above, row in
            row.speaker != nil && row.speaker == above.speaker && stamps[row.id] == nil ? row.id : nil
        })
        marks = ChatMark.enough(rows.compactMap { row in
            switch row {
            case .you(let message): ChatMark(id: message.id, kind: .said, preview: ChatMark.firstLine(message.text))
            case .cue, .result, .notes, .process: nil
            }
        })
    }

    static func read(from store: isolated CueStore) throws -> CueThread {
        let messages = try store.cueMessages(limit: limit)
        let waits = try CueWait.read(try store.cueWaiting(), handed: try store.cueDuty(), from: store)
        let pointed = messages.filter { !$0.shots.isEmpty }
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

    enum Row: Identifiable, Equatable, Sendable {
        case you(CueMessage)
        case cue(CueMessage, task: UUID?)
        case result(CueMessage, task: UUID)
        case notes([CueNoteRound])
        case process(CueMessage, touches: [CueActivity.Touch])

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.id
            case .notes(let rounds): rounds[0].id
            }
        }

        var date: Date {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.createdAt
            case .notes(let rounds): rounds[0].date
            }
        }

        var end: Date {
            if case .notes(let rounds) = self { rounds[rounds.count - 1].date } else { date }
        }

        var taskID: UUID? {
            switch self {
            case .cue(_, let task): task
            case .result(_, let task): task
            case .you, .notes, .process: nil
            }
        }

        var speaker: HorizontalEdge? {
            switch self {
            case .you: .trailing
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
            defer { previous = row.end }
            guard let previous else {
                stamps[row.id] = row.date
                continue
            }
            if row.date.timeIntervalSince(previous) >= ChatTime.gap || !calendar.isDate(row.date, inSameDayAs: previous) { stamps[row.id] = row.date }
        }
        return stamps
    }

    private static func rows(
        _ messages: [CueMessage], shots: [UUID: [CueShown]], lines: [UUID: CueMemoryLine]
    ) -> [Row] {
        var shown = Set<UUID>()
        var rows: [Row] = []
        for message in messages {
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if shots[message.id] != nil, let id = message.taskID {
                    shown.insert(id)
                    rows.append(.result(message, task: id))
                    continue
                }
                let task = message.taskID.flatMap { shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, task: task))
            case .note:
                guard message.text.isEmpty else { continue }
                var group: [CueNoteRound] = []
                if case .notes(let open) = rows.last {
                    group = open
                    rows.removeLast()
                }
                group.append(CueNoteRound(row: message, lines: lines))
                rows.append(.notes(group))
            case .round:
                let touches = CueActivity.touches(message.tools)
                if !touches.isEmpty { rows.append(.process(message, touches: touches)) }
            case nil: break
            }
        }
        return rows.compactMap { row in
            guard case .notes(let rounds) = row else { return row }
            let shown = rounds.filter { !$0.isEmpty }
            return shown.isEmpty ? nil : .notes(shown)
        }
    }
}

nonisolated struct CueShown: Identifiable, Equatable, Sendable {
    let preview: PreviewItem
    let look: String
    var id: UUID { preview.id }
}

