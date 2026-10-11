import CueStore
import Foundation

/// 会话页对话里的一条：你说的（右侧气泡），Pi 的一轮回答（左侧全宽，上面一行这一轮的经过），会话文件里的一行系统记录（压缩，居中一行小字），
/// 或 Agent 发到手机上看的一个文件（预览卡）。
nonisolated struct PiChatEntry: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, pi, system, preview }

    let id: UUID
    let role: Role
    let text: String
    /// Pi 回答上方的注脚（`PiChat.meta`）。
    let meta: PiChat.RoundNote?
    /// Pi 回答：这一轮的工具活动，点开 `meta` 那一行就地展开成清单
    var tools: PiChatMessage.Tools?
    /// 预览：要显示的预览记录
    var preview: PiPreview?

    var isUser: Bool { role == .user }
}

private nonisolated extension PiChatEntry.Role {
    init(_ role: PiChatRole) {
        self = switch role {
        case .user: .user
        case .pi: .pi
        case .system: .system
        }
    }
}

/// 会话页对话的规则（iOS 会话页、Mac 会话页共用）。
nonisolated enum PiChat {
    /// 对话按先后（消息已按 seq 升序）：你的话与 Pi 的回答各成一条，回答带这一轮的经过。认不出说话人的不显示。
    /// 对话只来自 Pi 的会话文件（唯一事实源），与终端里看到的一致。
    /// 预览卡不是会话文件里的内容（文件在 Agent 的命令行里发出，不留对话条），按创建时间插进对话：排在它创建之前最近的那条之后，
    /// 一轮里发的在你的话之后、这一轮的回答之前，比最后一条还晚的接在末尾（所有来源同一条规则）。
    static func entries(_ messages: [PiChatMessage], previews: [PiPreview] = []) -> [PiChatEntry] {
        var waiting = previews.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }[...]
        var entries: [PiChatEntry] = []
        func place(before time: Date?) {
            while let next = waiting.first, time.map({ next.createdAt < $0 }) ?? true {
                entries.append(PiChatEntry(id: next.id, role: .preview, text: next.title, meta: nil, preview: next))
                waiting.removeFirst()
            }
        }
        for message in messages {
            guard let role = message.role.known else { continue }
            place(before: message.at)
            entries.append(PiChatEntry(id: message.id, role: PiChatEntry.Role(role), text: message.text, meta: meta(message), tools: message.tools))
        }
        place(before: nil)
        return entries
    }

    /// Pi 回答上方注脚的内容（`ToolActivityLine` 排成一行）："改了 2 个文件，运行了 5 条命令 · 2 分钟"；
    /// 没调工具时只有用时（时长写法见 `PiClock.duration`）。失败的调用不在注脚里说：探索时的失败（搜不到、命令报错）是过程，
    /// 展开的清单里每条自己写状态。
    struct RoundNote: Equatable, Sendable {
        /// 工具摘要从全到简的几种写法（`toolSummaries`），放不下时取下一种；只有失败的工具时为空。
        var summaries: [String]
        var took: String
    }

    /// 你的话与系统行没有注脚。
    static func meta(_ message: PiChatMessage) -> RoundNote? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        let took = PiClock.duration(message.at.timeIntervalSince(started))
        return RoundNote(summaries: message.tools.map(toolSummaries) ?? [], took: took)
    }

    /// 一轮工具活动的一句话，从全到简："改了 2 个文件，读了 3 个文件" → "改了 2 个文件，其余 3 个"。分类按改文件、跑命令、读取、
    /// 搜索、其他的优先级，最全时三类以内全写、超过三类只写前两类；每简一档少写一类，少写的合计成"其余 N 个"。失败的不算进各类。
    static func toolSummaries(_ tools: PiChatMessage.Tools) -> [String] {
        let kinds = PiChatMessage.Tools.Kind.allCases.filter { tools[$0] > 0 }
        let most = kinds.count > 3 ? 2 : kinds.count
        return stride(from: most, through: 1, by: -1).map { listed in
            var parts = kinds.prefix(listed).map { phrase($0, tools[$0]) }
            let rest = kinds.dropFirst(listed).reduce(0) { $0 + tools[$1] }
            if rest > 0 { parts.append("其余 \(rest) 个") }
            return parts.joined(separator: "，")
        }
    }

    /// 改文件的行数："+12 −3"；没有增或没有删的那一半不写，算不出的也不写。
    static func diffLabel(added: Int?, removed: Int?) -> String {
        [added.flatMap { $0 > 0 ? "+\($0)" : nil }, removed.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }

    private static func phrase(_ kind: PiChatMessage.Tools.Kind, _ count: Int) -> String {
        switch kind {
        case .edit: "改了 \(count) 个文件"
        case .command: "运行了 \(count) 条命令"
        case .read: "读了 \(count) 个文件"
        case .search: "搜索了 \(count) 次"
        case .other: "调用了 \(count) 个工具"
        }
    }

    /// 你发出、还没出现在对话里的话（对话里还没有 `deliveryID` 等于它的消息）：作为你的气泡接在末尾，写送达情况。
    /// 排队的话（`queued`）不在这里：它们在回复框上方一叠，同一句话只出现一处。
    /// 作答、斜杠命令、设置、开新会话、补写对话这些不是你说的话，不算（命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉）。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        unanswered(deliveries, messages: messages).filter { !isQueued($0) }
    }

    /// 排队的话：Agent 在跑时"等它做完再说"发出、还没进对话（它还没开始处理）的，按发出先后。没能送达的不算——它是对话末尾的气泡，
    /// 在那里重发或移除。显示在回复框上方一叠（`PiQueueStack`）；还没被 Mac 领取的能撤回或改为马上说（`DeliveryRequest.isWithdrawable`）。
    static func queued(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        unanswered(deliveries, messages: messages).filter(isQueued)
    }

    private static func isQueued(_ request: DeliveryRequest) -> Bool {
        request.mode == .known(.followUp) && request.status != .known(.failed)
    }

    private static func unanswered(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { request in
            guard let mode = request.mode.known, [.send, .steer, .followUp].contains(mode) else { return false }
            return !arrived.contains(request.id)
        }
    }

    /// 你发出的一句话给人看的写法：带卡片的写卡片标题与图片数，不露存储格式。
    static func shownText(of request: DeliveryRequest) -> Dotted {
        let card = CardText(request.content)
        guard !card.images.isEmpty else { return Dotted(request.content) }
        return Dotted(card.title, "\(card.images.count) 张图片")
    }

    /// 你在这个会话里说过的最近一句（对话里最后一条你的消息）：空回复框按 ↑ 调回它。
    static func lastSaid(_ messages: [PiChatMessage]) -> String? {
        messages.last { $0.role == .known(.user) }?.text
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
