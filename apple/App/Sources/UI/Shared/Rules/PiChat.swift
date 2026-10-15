import CueStore
import CueText
import Foundation

/// 会话页对话里的一条：你说的（右侧气泡），Pi 的一轮回答（左侧全宽，上面一块这一轮的经过），会话文件里的一行系统记录（压缩，居中一行小字），
/// 扩展投进来的机器消息（FireCode 交回子代理结果、审查结论……，一块信封一张卡片），或 Agent 一次发到手机上看的几个文件（一张预览卡）。
nonisolated struct PiChatEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, pi, notice(PiNotice), machine, preview }

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
    /// 用户一方的这句是 Cue 发进会话的（`PiChatMessage.saidByCue`，Cue 的 peek 同一条）：气泡上标出 Cue。
    var fromCue = false

    var isUser: Bool { role == .user }
}

private nonisolated extension PiChatEntry.Role {
    /// 认不出的（别的版本写的系统行）为 nil。
    init?(_ message: PiChatMessage) {
        switch message.role.known {
        case .user: self = .user
        case .pi: self = .pi
        case .machine: self = .machine
        case .system: guard let notice = message.notice else { return nil }; self = .notice(notice)
        case nil: return nil
        }
    }
}

/// 会话页对话的规则（iOS 会话页、Mac 会话页共用）。
nonisolated enum PiChat {
    /// 对话按先后（消息已按 seq 升序）：你的话与 Pi 的回答各成一条，回答带这一轮的经过。认不出说话人的不显示。
    /// 对话只来自 Pi 的会话文件（唯一事实源），与终端里看到的一致。
    /// 预览卡不是会话文件里的内容（文件在 Agent 的命令行里发出，不留对话条），按创建时间插进对话：排在它创建之前最近的那条之后，
    /// 一轮里发的在你的话之后、这一轮的回答之前，比最后一条还晚的接在末尾（所有来源同一条规则）。一批的创建时间相同（`CueStore.addPreviews`），是一张卡。
    /// `cueSent` 是 Cue 说的那几条的请求 id（`SessionDigest.cueSent`，按发送记录认）：带着其中之一的用户消息标成 Cue 说的。
    static func entries(_ messages: [PiChatMessage], previews: [PiPreview] = [], cueSent: Set<UUID> = []) -> [PiChatEntry] {
        var waiting = previews.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }[...]
        var entries: [PiChatEntry] = []
        func place(before time: Date?) {
            while let next = waiting.first, time.map({ next.createdAt < $0 }) ?? true {
                let batch = Array(waiting.prefix { $0.createdAt == next.createdAt })
                entries.append(PiChatEntry(id: next.id, role: .preview, text: next.title, took: nil, previews: batch))
                waiting.removeFirst(batch.count)
            }
        }
        for message in messages {
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

    /// 一轮经过的一句（`RoundProcess` 的标题行，做完的回答与在跑的这一轮同一种写法）："跑了 12 步 · 改了 3 个文件 · 1 处出错"。
    /// 步数是各类调用的合计（读、改同一个文件只算一步，与清单的行同一口径）；没改文件、没出错的那一截不写。出错的那一截要标胭脂，单独给出。
    struct ProcessLine: Equatable {
        var steps: Dotted
        var failures: String?
    }

    static func processLine(_ tools: PiChatMessage.Tools) -> ProcessLine {
        let failures = tools.items.count(where: \.failed)
        return ProcessLine(
            steps: Dotted("跑了 \(tools.total) 步", tools.edits > 0 ? "改了 \(tools.edits) 个文件" : nil),
            failures: failures > 0 ? "\(failures) 处出错" : nil)
    }

    /// 经过收起时也列出的几步：改了的文件与出错的调用（清单里总有它们，见 `PiChatMessage.Tools.items`），按先后。
    static func pinned(_ tools: PiChatMessage.Tools) -> [PiChatMessage.Tools.Item] {
        tools.items.filter { $0.failed || $0.kind == .edit }
    }

    /// 改文件的行数："+12 −3"；没有增或没有删的那一半不写，算不出的也不写。
    static func diffLabel(added: Int?, removed: Int?) -> String {
        [added.flatMap { $0 > 0 ? "+\($0)" : nil }, removed.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }

    /// 你发出、Agent 还没读到、也不在排队的话（`queued` 之外的）：作为你的气泡接在末尾，写送达情况——直接说的还在路上、
    /// Agent 当场开始读了而对话还没跟上的，与没能送达的（任何方式都是，在那里重发或移除）。同一句话只出现一处。
    /// 作答、斜杠命令、设置、开新会话、补写对话这些不是你说的话，不算（命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉）。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [PiChatMessage], at moment: Speech.Moment) -> [DeliveryRequest] {
        unread(deliveries, messages: messages).filter { !isQueued($0, at: moment) }
    }

    /// 排队的话：Agent 在跑时"等它做完再说""马上说"发出、它还没读到的，按发出先后，在回复框上方一叠（`PiQueueStack`）。
    /// 事实只有投送请求与对话两处：方式在执行前是你选的，送到后是 Agent 实际怎么收下的（`DeliveryMode`，排进它的队列才是这两种）；
    /// 它读到的那一刻对话里出现这句（`deliveryID`），就从这一叠移进对话、落在被读到的位置。没能送达的不算（含超时）——它是对话末尾的气泡。
    static func queued(_ deliveries: [DeliveryRequest], messages: [PiChatMessage], at moment: Speech.Moment) -> [DeliveryRequest] {
        unread(deliveries, messages: messages).filter { isQueued($0, at: moment) }
    }

    private static func isQueued(_ request: DeliveryRequest, at moment: Speech.Moment) -> Bool {
        guard request.mode == .known(.followUp) || request.mode == .known(.steer) else { return false }
        return Speech.trip(request, at: moment).failure == nil
    }

    /// 排队的一句此刻到哪了：还没交到 Agent 手上是发送中（Mac 没领取时还撤得回）；排进它的队列后说什么时候读到——
    /// 马上说的在这一步（当前的工具调用）做完后读，等它做完再说的在这一轮做完后读。
    static func queueNote(of request: DeliveryRequest, at moment: Speech.Moment) -> Dotted {
        guard Speech.trip(request, at: moment) == .delivered else { return "发送中" }
        return Dotted("排队中", request.mode == .known(.steer) ? "Agent 做完这一步就会读到" : "Agent 做完这一轮就会读到")
    }

    private static func unread(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { request in
            guard let mode = request.mode.known, [.send, .steer, .followUp].contains(mode) else { return false }
            return !arrived.contains(request.id)
        }
    }

    /// 排队的一句话在一行里的写法：标题与图片数，不露存储格式（排队的话只占一行，图片数代替缩略图）。
    static func shownText(of request: DeliveryRequest) -> Dotted {
        let card = CardText(request.content)
        return Dotted(card.title, card.images.isEmpty ? nil : "\(card.images.count) 张图片")
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
