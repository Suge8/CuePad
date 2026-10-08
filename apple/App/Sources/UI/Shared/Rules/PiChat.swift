import CueStore
import Foundation

/// 会话页对话里的一条：你说的（右侧气泡），或 Pi 的一轮回答（左侧全宽，上面一行这一轮的经过）。
nonisolated struct PiChatEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let isUser: Bool
    let text: String
    let meta: String?
}

/// 会话页对话的规则（iOS 会话页、Mac 会话页共用）。
nonisolated enum PiChat {
    /// 对话按先后（消息已按 seq 升序）：你的话与 Pi 的回答各成一条，回答带这一轮的经过。认不出说话人的不显示。
    static func entries(_ messages: [PiChatMessage]) -> [PiChatEntry] {
        messages.compactMap { message in
            guard let role = message.role.known else { return nil }
            return PiChatEntry(id: message.id, isUser: role == .user, text: message.text, meta: meta(message))
        }
    }

    /// Pi 回答上方的一行："运行了 5 个工具 · 2 分"；没调工具时"用时 8 秒"（时长写法见 `PiClock.duration`）。你的话没有。
    static func meta(_ message: PiChatMessage) -> String? {
        guard message.role == .known(.pi), let started = message.roundStartedAt else { return nil }
        let took = PiClock.duration(message.at.timeIntervalSince(started))
        return message.toolCount > 0 ? "运行了 \(message.toolCount) 个工具 · \(took)" : "用时 \(took)"
    }

    /// 你发出、还没出现在对话里的话（对话里还没有 `deliveryID` 等于它的消息）：作为你的气泡接在末尾，写送达情况。
    /// 作答、开新会话、补写对话这些不是你说的话，不算。
    static func outgoing(_ deliveries: [DeliveryRequest], messages: [PiChatMessage]) -> [DeliveryRequest] {
        let arrived = Set(messages.compactMap(\.deliveryID))
        return deliveries.filter { request in
            guard let mode = request.mode.known, [.send, .steer, .followUp, .paste, .command].contains(mode) else { return false }
            return !arrived.contains(request.id)
        }
    }

    /// 对话只同步最近 `transcriptWindow` 内活跃过的会话；更早的会话打开时没有对话，请它所在的 Mac 补写。
    static let transcriptWindow: TimeInterval = 7 * 86_400

    static func needsTranscript(_ session: PiSessionState, messages: [PiChatMessage], now: Date = .now) -> Bool {
        messages.isEmpty && now.timeIntervalSince(session.stateSince) > transcriptWindow
    }
}
