import CueStore
import Foundation

/// 会话页对话里的一条：你说的（右侧气泡），Pi 的一轮回答（左侧全宽，上面一行这一轮的经过），会话文件里的一行系统记录（压缩，居中一行小字），
/// 或 Agent 发到手机上看的一个文件（预览卡）。
nonisolated struct PiChatEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: PiChatRole
    let text: String
    let meta: String?
    /// 预览：要显示的预览记录
    var preview: PiPreview?

    var isUser: Bool { role == .user }
}

/// 会话页对话的规则（iOS 会话页、Mac 会话页共用）。
nonisolated enum PiChat {
    /// 对话按先后（消息已按 seq 升序）：你的话与 Pi 的回答各成一条，回答带这一轮的经过。认不出说话人的不显示。
    /// 对话只来自 Pi 的会话文件（唯一事实源），与终端里看到的一致。
    /// 预览卡的位置就是会话文件里工具调用那一行的位置（`.preview` 消息，正文是预览 id），预览记录只提供文件与标题：
    /// 记录还没同步到的先不显示；没有对应对话条的预览（命令行投的）按时间接在末尾。
    static func entries(_ messages: [PiChatMessage], previews: [PiPreview] = []) -> [PiChatEntry] {
        let byID = Dictionary(previews.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var placed: Set<UUID> = []
        var entries: [PiChatEntry] = messages.compactMap { message in
            guard let role = message.role.known else { return nil }
            guard role == .preview else { return PiChatEntry(id: message.id, role: role, text: message.text, meta: meta(message)) }
            guard let preview = byID[message.text.lowercased()] else { return nil }
            placed.insert(preview.id)
            return PiChatEntry(id: message.id, role: role, text: message.text, meta: nil, preview: preview)
        }
        entries += previews.filter { !placed.contains($0.id) }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { PiChatEntry(id: $0.id, role: .preview, text: $0.id.uuidString.lowercased(), meta: nil, preview: $0) }
        return entries
    }

    /// Pi 回答上方的一行："运行了 5 个工具 · 2 分"；没调工具时"用时 8 秒"（时长写法见 `PiClock.duration`）。你的话没有。
    static func meta(_ message: PiChatMessage) -> String? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        let took = PiClock.duration(message.at.timeIntervalSince(started))
        return message.toolCount > 0 ? "运行了 \(message.toolCount) 个工具 · \(took)" : "用时 \(took)"
    }

    /// 你发出、还没出现在对话里的话（对话里还没有 `deliveryID` 等于它的消息）：作为你的气泡接在末尾，写送达情况。
    /// 作答、斜杠命令、设置、开新会话、补写对话这些不是你说的话，不算（命令在会话文件里没有带请求 id 的用户消息，挂了永远换不掉）。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { request in
            guard let mode = request.mode.known, [.send, .steer, .followUp].contains(mode) else { return false }
            return !arrived.contains(request.id)
        }
    }

    /// 会话页顶栏状态后的一句：你发出的话里有几句没能送达（它们还挂在对话末尾等你重发或移除）。列表那一行写"没能送达"，
    /// 进来顶栏就不能只写会话自己的状态，像是已经好了。没有时是 nil。
    static func undeliveredNote(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> String? {
        let count = outgoing(deliveries, messages: messages).filter { $0.status == .known(.failed) }.count
        return count > 0 ? "\(count) 句没送到" : nil
    }

    /// 对话只同步最近 `transcriptWindow` 内活跃过的会话；更早的会话打开时没有对话，请它所在的 Mac 补写。
    static let transcriptWindow: TimeInterval = 7 * 86_400

    static func needsTranscript(_ session: PiSessionState, messages: [PiChatMessage], now: Date = .now) -> Bool {
        messages.isEmpty && now.timeIntervalSince(session.stateSince) > transcriptWindow
    }
}
