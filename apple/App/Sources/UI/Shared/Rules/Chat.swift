import CueStore
import Foundation

nonisolated struct ChatEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user, answer, pi, notice(ChatNotice), machine, preview
        case outgoing(DeliveryRequest)

        var isOutgoing: Bool { if case .outgoing = self { true } else { false } }
    }

    let id: UUID
    let role: Role
    let text: String
    let took: String?
    var tools: ChatMessage.Tools?
    var previews: [PreviewItem] = []
    var question: String?
    var fromCue = false
    /// 你说的这句在途时已经作为请求（`outgoing`）摆在对话里：落库后换成的这一条接在同一处，不再淡入一遍；还在飞的话按请求的编号接着认领（`SendFlight`）。
    var replaces: UUID?

    /// 到的时候等上面让开、再在终位淡入（`AnyTransition.arrival`）：别处发来的一句、一轮被停下的那行字。
    var arrivesLate: Bool {
        switch role {
        case .user: replaces == nil
        case .notice(let notice): !notice.changesContext
        default: false
        }
    }
}

private nonisolated extension ChatEntry {
    static func outgoing(_ request: DeliveryRequest) -> ChatEntry {
        ChatEntry(id: request.id, role: .outgoing(request), text: request.content, took: nil, fromCue: request.isFromCue)
    }
}

private nonisolated extension ChatEntry.Role {
    init?(_ message: ChatMessage) {
        switch message.role.known {
        case .user: self = .user
        case .pi: self = .pi
        case .machine: self = .machine
        case .answer: self = .answer
        case .system: guard let notice = message.notice else { return nil }; self = .notice(notice)
        case nil: return nil
        }
    }
}

private nonisolated enum Timed {
    case answer(ChatMessage)
    case preview(PreviewItem)
    case stranded(DeliveryRequest)

    var at: Date {
        switch self {
        case .answer(let message): message.at
        case .preview(let preview): preview.createdAt
        case .stranded(let request): request.createdAt
        }
    }
}

nonisolated enum Chat {
    static func entries(
        _ messages: [ChatMessage], previews: [PreviewItem] = [], deliveries: [DeliveryRequest] = [], cueSent: Set<UUID> = [],
        at moment: Speech.Moment = .always()
    ) -> [ChatEntry] {
        let outgoing = Self.outgoing(deliveries, messages: messages)
        let tail = outgoing.firstIndex { Speech.trip($0, at: moment).failure == nil } ?? outgoing.endIndex
        let answers = messages.filter { $0.role == .known(.answer) }.map { (at: $0.at, key: $0.id.uuidString, item: Timed.answer($0)) }
        let batches = previews.map { (at: $0.createdAt, key: $0.id.uuidString, item: Timed.preview($0)) }
        let stranded = outgoing[..<tail].map { (at: $0.createdAt, key: $0.id.uuidString, item: Timed.stranded($0)) }
        var waiting = (answers + batches + stranded).sorted { ($0.at, $0.key) < ($1.at, $1.key) }.map(\.item)[...]
        let requested = Set(deliveries.map(\.id))
        var entries: [ChatEntry] = []
        func place(before time: Date?) {
            while let next = waiting.first, time.map({ next.at < $0 }) ?? true {
                switch next {
                case .answer(let message):
                    entries.append(ChatEntry(id: message.id, role: .answer, text: message.shown, took: nil, question: message.question))
                    waiting.removeFirst()
                case .preview(let first):
                    let batch = waiting.prefix { if case .preview(let preview) = $0 { preview.createdAt == first.createdAt } else { false } }
                        .compactMap { if case .preview(let preview) = $0 { preview } else { nil } }
                    entries.append(ChatEntry(id: first.id, role: .preview, text: first.title, took: nil, previews: batch))
                    waiting.removeFirst(batch.count)
                case .stranded(let request):
                    entries.append(.outgoing(request))
                    waiting.removeFirst()
                }
            }
        }
        for message in messages where message.role != .known(.answer) {
            guard let role = ChatEntry.Role(message) else { continue }
            place(before: message.at)
            entries.append(ChatEntry(
                id: message.id, role: role, text: message.text, took: took(message), tools: message.tools,
                fromCue: message.saidByCue(cueSent), replaces: message.deliveryID.flatMap { requested.contains($0) ? $0 : nil }))
        }
        place(before: nil)
        entries += outgoing[tail...].map(ChatEntry.outgoing)
        return entries
    }

    static func took(_ message: ChatMessage) -> String? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        return SessionClock.duration(message.at.timeIntervalSince(started))
    }

    struct Process: Equatable {
        struct Count: Equatable {
            let kind: ChatMessage.Tools.Kind
            let count: Int
            let spoken: String
        }

        var counts: [Count] = []
        var steps: String?
        var recached: String?

        var spoken: Dotted { Dotted(counts.map(\.spoken) + [steps]) }
    }

    static func process(_ tools: ChatMessage.Tools?) -> Process? {
        guard let tools else { return nil }
        let recached = tools.cache?.recached.map { String(localized: "缓存失效，重读 \(CueContext.tokens($0))") }
        guard tools.steps > 0 else { return recached.map { Process(recached: $0) } }
        let edits = tools.items.count { $0.kind == .edit && !$0.failed }
        var counts = [Process.Count(kind: .edit, count: edits, spoken: String(localized: "改了 \(edits) 个文件"))]
        let complete = tools.steps == tools.items.count { $0.kind != .said }
        if complete { counts += looks(tools.items) }
        counts.removeAll { $0.count == 0 }
        return Process(counts: counts, steps: complete && !counts.isEmpty ? nil : String(localized: "共 \(tools.steps) 步"), recached: recached)
    }

    enum ProcessPart: Hashable, Identifiable {
        case steps(Range<Int>)
        case said(Int)

        var id: Int {
            switch self {
            case .steps(let range): range.lowerBound
            case .said(let index): index
            }
        }
    }

    static func parts(_ items: [ChatMessage.Tools.Item]) -> [ProcessPart] {
        var parts: [ProcessPart] = [], start = 0
        for (index, item) in items.enumerated() where item.kind == .said {
            if index > start { parts.append(.steps(start..<index)) }
            parts.append(.said(index))
            start = index + 1
        }
        if items.count > start { parts.append(.steps(start..<items.count)) }
        return parts
    }

    static func looks(_ items: some Collection<ChatMessage.Tools.Item>) -> [Process.Count] {
        func count(_ kind: ChatMessage.Tools.Kind) -> Int { items.count { $0.kind == kind } }
        let commands = count(.command), reads = count(.read), searches = count(.search), others = count(.other)
        return [
            Process.Count(kind: .command, count: commands, spoken: String(localized: "跑了 \(commands) 条命令")),
            .init(kind: .read, count: reads, spoken: String(localized: "读了 \(reads) 个文件")),
            .init(kind: .search, count: searches, spoken: String(localized: "搜了 \(searches) 次")),
            .init(kind: .other, count: others, spoken: String(localized: "\(others) 次工具")),
        ].filter { $0.count > 0 }
    }

    static func keys(_ tools: ChatMessage.Tools?) -> Set<String> {
        Set(tools?.items.compactMap { $0.record?.uuidString ?? $0.calls?.first } ?? [])
    }

    /// 最新那条做完的回答。被停下的那一轮说过的话也落成一条回答，后面跟着"已停止"，不算：在跑时再说一句是打断这一轮、以这句接着做，
    /// 各家这时状态一路是在跑，把那条当成在跑的这一轮的回答，角色就交给它、让开，整段思考都不见了。
    static func answer(in messages: [ChatMessage]) -> ChatMessage? {
        var stopped = false
        for message in messages.reversed() {
            switch message.role.known {
            case .system: if message.notice == .stopped || message.notice == .declined { stopped = true }
            case .user, .machine: stopped = false
            case .pi:
                guard stopped else { return message }
                stopped = false
            case .answer, nil: break
            }
        }
        return nil
    }

    static func landed(_ pending: ChatMessage.Tools, in reply: ChatMessage?) -> Bool {
        guard let reply else { return false }
        return !keys(pending).isDisjoint(with: keys(reply.tools).union([reply.id.uuidString]))
    }

    enum ProcessRow: Hashable {
        case step(Int)
        case looks(Range<Int>)
    }

    static let foldedLooks = 3

    static func rows(_ items: ArraySlice<ChatMessage.Tools.Item>, settled: Bool) -> [ProcessRow] {
        guard settled else { return items.indices.map(ProcessRow.step) }
        var rows: [ProcessRow] = [], start = items.startIndex
        func close(at end: Int) {
            rows += end - start >= foldedLooks ? [.looks(start..<end)] : (start..<end).map(ProcessRow.step)
            start = end + 1
        }
        for index in items.indices where items[index].kind.acts {
            close(at: index)
            rows.append(.step(index))
        }
        close(at: items.endIndex)
        return rows == [.looks(items.indices)] ? items.indices.map(ProcessRow.step) : rows
    }

    static func diffLabel(added: Int?, removed: Int?) -> String {
        [added.flatMap { $0 > 0 ? "+\($0)" : nil }, removed.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }

    /// 作答、斜杠命令、设置这些不是你说的话，不算：命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [ChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { $0.mode == .known(.send) && !arrived.contains($0.id) }
    }

    static func lastSaid(_ messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .known(.user) }.map { SkillCall.shown($0.text) }?.nonEmpty
    }

    static func undeliveredNote(_ count: Int) -> String? { count > 0 ? String(localized: "\(count) 句没送到") : nil }

    static let transcriptWindow: TimeInterval = 7 * 86_400

    static func needsTranscript(_ session: SessionState, messages: [ChatMessage]) -> Bool {
        messages.isEmpty && Date.now.timeIntervalSince(session.stateSince) > transcriptWindow
    }
}
