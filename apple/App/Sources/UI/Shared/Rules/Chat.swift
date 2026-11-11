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
    /// 你的话是存储格式正文（`CueFormat`，可带图片），其余是纯文字或 Markdown
    let text: String
    let took: String?
    var tools: ChatMessage.Tools?
    var previews: [PreviewItem] = []
    var question: String?
    var fromCue = false
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
    /// 对话来自 Pi 的会话文件，与终端里看到的一致；不在文件里的两种按时刻插进对话：预览卡（文件在 Agent 的命令行里发出，不留对话条）按创建时间，
    /// 你的作答（`ChatRole.answer`，由作答的 Mac 写进对话）按答的那一刻。
    /// 你发出、还没进对话的话（`outgoing`）与 Cue 页你的话同一条规则：还在路上的接在最末——Agent 读到时它就进对话的末尾，换下时不挪位；没能送达的不会再进对话，留在你说它的那一刻。
    /// `cueSent`：Cue 说的那几条的请求 id（`SessionDigest.cueSent`，按发送记录认）。
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
                fromCue: message.saidByCue(cueSent)))
        }
        place(before: nil)
        return entries + outgoing[tail...].map(ChatEntry.outgoing)
    }

    static func took(_ message: ChatMessage) -> String? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        return SessionClock.duration(message.at.timeIntervalSince(started))
    }

    /// 步数是调用数（读、改同一个文件只算一步，与清单的行同一口径）。不写出错几处：中途出的错它多半自己解决了，没解决的回答里会说；哪步出错展开清单在原位标着。
    static func processLine(_ tools: ChatMessage.Tools?) -> Dotted? {
        guard let tools, tools.steps > 0 else { return nil }
        let edits = tools.items.count { $0.kind == .edit && !$0.failed }
        return Dotted([String(localized: "跑了 \(tools.steps) 步"), edits > 0 ? String(localized: "改了 \(edits) 个文件") : nil])
    }

    static func diffLabel(added: Int?, removed: Int?) -> String {
        [added.flatMap { $0 > 0 ? "+\($0)" : nil }, removed.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }

    /// 作答、斜杠命令、设置这些不是你说的话，不算：命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [ChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { $0.mode == .known(.send) && !arrived.contains($0.id) }
    }

    static func sending(_ deliveries: [DeliveryRequest], messages: [ChatMessage], at moment: Speech.Moment) -> Bool {
        outgoing(deliveries, messages: messages).contains { Speech.trip($0, at: moment).inTransit }
    }

    static func lastSaid(_ messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .known(.user) }.map { SkillCall.shown($0.text) }?.nonEmpty
    }

    /// 会话页顶栏状态后与会话行（你看过以后）的小标记两处同一个数，来自 `SessionListItem.undelivered`。
    static func undeliveredNote(_ count: Int) -> String? { count > 0 ? String(localized: "\(count) 句没送到") : nil }

    /// 对话只同步最近这么久内活跃过的会话（Mac 的历史索引按它决定读不读对话），对话也在会话安静这么久之后清理；
    /// 更早的会话打开时没有对话，请它所在的 Mac 补写。
    static let transcriptWindow: TimeInterval = 7 * 86_400

    static func needsTranscript(_ session: SessionState, messages: [ChatMessage]) -> Bool {
        messages.isEmpty && Date.now.timeIntervalSince(session.stateSince) > transcriptWindow
    }
}
