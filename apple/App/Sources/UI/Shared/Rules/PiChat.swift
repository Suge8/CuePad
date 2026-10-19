import CueStore
import CueText
import Foundation

/// 会话页对话里的一条：你说的（右侧气泡），你在 CuePad 里答了它的提问（右侧气泡，带一行答的是哪个问题），
/// Pi 的一轮回答（左侧全宽，上面一块这一轮的经过），会话文件里的一行系统记录（压缩，居中一行小字），
/// 扩展投进来的机器消息（FireCode 交回子代理结果、审查结论……，一块信封一张卡片），或 Agent 一次发到手机上看的几个文件（一张预览卡）。
nonisolated struct PiChatEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, answer, pi, notice(PiNotice), machine, preview }

    let id: UUID
    let role: Role
    /// 你的话是存储格式正文（`CueFormat`，可带图片），其余是纯文字或 Markdown
    let text: String
    /// Pi 回答：这一轮做了多久（`PiChat.took`）；你的话与系统行为 nil。
    let took: String?
    /// Pi 回答：这一轮的工具活动（`RoundProcess` 排成上方那一块）
    var tools: PiChatMessage.Tools?
    /// 预览卡：一次发来的几个文件，按发的先后
    var previews: [PiPreview] = []
    /// 你的作答：答的是哪个问题（问题原文；更旧的版本写的没有）
    var question: String?
    /// 用户一方的这句是 Cue 发进会话的（`PiChatMessage.saidByCue`，Cue 的 peek 同一条）：气泡上标出 Cue。
    var fromCue = false
}

private nonisolated extension PiChatEntry.Role {
    /// 认不出的（别的版本写的系统行）为 nil。
    init?(_ message: PiChatMessage) {
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

/// 按时刻插进对话的一条（`PiChat.entries`）。
private nonisolated enum Timed {
    case answer(PiChatMessage)
    case preview(PiPreview)

    var at: Date {
        switch self {
        case .answer(let message): message.at
        case .preview(let preview): preview.createdAt
        }
    }
}

/// 会话页对话的规则（iOS 会话页、Mac 会话页共用）。
nonisolated enum PiChat {
    /// 对话按先后（消息已按 seq 升序）：你的话与 Pi 的回答各成一条，回答带这一轮的经过。认不出说话人的不显示。
    /// 对话来自 Pi 的会话文件，与终端里看到的一致；只有你在 CuePad 里的作答不在文件里，由作答的 Mac 写进对话（`PiChatRole.answer`）。
    /// 不在会话文件里的两种按时刻插进对话：预览卡（文件在 Agent 的命令行里发出，不留对话条）按创建时间，你的作答（`PiChatRole.answer`）按答的那一刻。
    /// 排在那一刻之前最近的那条之后：一轮里发的、答的在你的话之后、这一轮的回答之前，比最后一条还晚的接在末尾（所有来源同一条规则）。
    /// 一批预览的创建时间相同（`CueStore.addPreviews`），是一张卡。
    /// `cueSent` 是 Cue 说的那几条的请求 id（`SessionDigest.cueSent`，按发送记录认）：带着其中之一的用户消息标成 Cue 说的。
    static func entries(_ messages: [PiChatMessage], previews: [PiPreview] = [], cueSent: Set<UUID> = []) -> [PiChatEntry] {
        let answers = messages.filter { $0.role == .known(.answer) }.map { (at: $0.at, key: $0.id.uuidString, item: Timed.answer($0)) }
        let batches = previews.map { (at: $0.createdAt, key: $0.id.uuidString, item: Timed.preview($0)) }
        var waiting = (answers + batches).sorted { ($0.at, $0.key) < ($1.at, $1.key) }.map(\.item)[...]
        var entries: [PiChatEntry] = []
        func place(before time: Date?) {
            while let next = waiting.first, time.map({ next.at < $0 }) ?? true {
                switch next {
                case .answer(let message):
                    entries.append(PiChatEntry(id: message.id, role: .answer, text: message.text, took: nil, question: message.question))
                    waiting.removeFirst()
                case .preview(let first):
                    let batch = waiting.prefix { if case .preview(let preview) = $0 { preview.createdAt == first.createdAt } else { false } }
                        .compactMap { if case .preview(let preview) = $0 { preview } else { nil } }
                    entries.append(PiChatEntry(id: first.id, role: .preview, text: first.title, took: nil, previews: batch))
                    waiting.removeFirst(batch.count)
                }
            }
        }
        for message in messages where message.role != .known(.answer) {
            guard let role = PiChatEntry.Role(message) else { continue }
            place(before: message.at)
            entries.append(PiChatEntry(
                id: message.id, role: role, text: message.text, took: took(message), tools: message.tools,
                fromCue: message.saidByCue(cueSent)))
        }
        place(before: nil)
        return entries
    }

    /// Pi 回答这一轮做了多久（时长写法见 `PiClock.duration`）；你的话与系统行没有。
    static func took(_ message: PiChatMessage) -> String? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        return PiClock.duration(message.at.timeIntervalSince(started))
    }

    /// 一轮经过的一句（`RoundProcess` 的标题行；会话与 Cue、做完的与在跑的同一种写法）："跑了 12 步 · 改了 3 个文件"、
    /// "跑了 6 步 · 对 2 个会话说话 · 做完 1 件"。步数是调用数（读、改同一个文件只算一步，与清单的行同一口径）；
    /// 后面逐类写落了结果的几步（`Kind.acts`，做成了的，没有的那类不写；对会话说话按会话算）。不写出错几处：中途出的错它多半自己解决了，
    /// 没解决的回答里会说；哪步出错展开清单在原位标着。没调过工具的一轮没有这一句。
    static func processLine(_ tools: PiChatMessage.Tools?) -> Dotted? {
        guard let tools, tools.steps > 0 else { return nil }
        let acts = tools.items.filter { $0.kind.acts && !$0.failed }
        func phrase(_ kind: PiChatMessage.Tools.Kind, _ write: (Int) -> String) -> String? {
            let done = acts.filter { $0.kind == kind }
            let count = kind == .talk ? Set(done.map { $0.task?.uuidString ?? $0.target }).count : done.count
            return count > 0 ? write(count) : nil
        }
        return Dotted([
            "跑了 \(tools.steps) 步",
            phrase(.edit) { "改了 \($0) 个文件" },
            phrase(.add) { "建了 \($0) 件任务" },
            phrase(.start) { "开工 \($0) 件" },
            phrase(.talk) { "对 \($0) 个会话说话" },
            phrase(.stop) { "停下 \($0) 个会话" },
            phrase(.done) { "做完 \($0) 件" },
            phrase(.ask) { "问你 \($0) 件" },
        ])
    }

    /// 改文件的行数："+12 −3"；没有增或没有删的那一半不写，算不出的也不写。
    static func diffLabel(added: Int?, removed: Int?) -> String {
        [added.flatMap { $0 > 0 ? "+\($0)" : nil }, removed.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }

    /// 你发出、Agent 还没读到的话：作为你的气泡接在末尾，写送达情况——还在路上、Agent 已经接过去而对话还没跟上的，
    /// 与没能送达的（在那里重发或移除）。Agent 读到的那一刻对话里出现这句（`deliveryID`），气泡换成对话里的那条。
    /// 作答、斜杠命令、设置、开新会话、补写对话这些不是你说的话，不算（命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉）。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { $0.mode == .known(.send) && !arrived.contains($0.id) }
    }

    /// 回复框空着时的发送中：接在末尾的你的话里还有在路上的（与那个气泡同一个事实）。
    static func sending(_ deliveries: [DeliveryRequest], messages: [PiChatMessage], at moment: Speech.Moment) -> Bool {
        outgoing(deliveries, messages: messages).contains { Speech.trip($0, at: moment) == .sending }
    }

    /// 你在这个会话里说过的最近一句（对话里最后一条你的消息，存储格式，文字与图片）：空回复框按 ↑ 调回它。
    static func lastSaid(_ messages: [PiChatMessage]) -> String? {
        messages.last { $0.role == .known(.user) }?.text.nonEmpty
    }

    /// 有几句没能送达时的说法（它们还挂在对话末尾等你重发或移除）："1 句没送到"；数来自会话列表查询（`PiSessionListItem.undelivered`）。
    /// 会话页顶栏状态后写它，会话行在你看过以后（不再整行写"没能送达"）留一个小标记、读屏念它：两处同一个数。没有时是 nil。
    static func undeliveredNote(_ count: Int) -> String? { count > 0 ? "\(count) 句没送到" : nil }

    /// 对话只同步最近 `transcriptWindow` 内活跃过的会话；更早的会话打开时没有对话，请它所在的 Mac 补写。
    static let transcriptWindow: TimeInterval = 7 * 86_400

    static func needsTranscript(_ session: PiSessionState, messages: [PiChatMessage], now: Date = .now) -> Bool {
        messages.isEmpty && now.timeIntervalSince(session.stateSince) > transcriptWindow
    }
}
