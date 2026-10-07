import CueStore
import Foundation

/// "发到 Mac"的界面规则：会话此刻可用哪些发送方式。请求本身经 `AppServices.requestMacDelivery` 写出。
nonisolated enum MacDelivery {
    /// 会话此刻可用的方式，第一个是默认：Pi 正在跑一轮时直接发送会被拒绝，只能等它做完再说（默认，不打断）或马上说（次级，按住发送钮）。
    /// 已结束的会话也能直接发送：Mac 会在后台把它恢复起来再送达。
    /// Mac 上还可以只放进输入框再自己按发送（只对开在终端里的会话；含图片时不能）；手机不给（人不在 Mac 前，没人去按那一下发送）。
    static func modes(for session: PiSessionState, hasImages: Bool) -> [DeliveryMode] {
        let sending: [DeliveryMode] = session.state.known?.isTurnRunning == true ? [.followUp, .steer] : [.send]
        #if os(macOS)
        let inTerminal = !session.hosted && session.state != .known(.ended)
        return hasImages || !inTerminal ? sending : sending + [.paste]
        #else
        return sending
        #endif
    }
}

/// 回复框此刻该做什么：发消息（可用的方式，第一个是默认）、就是作答框（文字型问题）、
/// 先在上面作答（选择、确认型问题：自由文本发出去会一直挂着，Pi 不答完题不会去看）、这里答不了（只能在 Mac 上答）。
nonisolated enum PiReply: Equatable {
    case message([DeliveryMode])
    case answer(PiQuestion)
    case answerAbove
    case unanswerable
}

extension MacDelivery {
    static func reply(to session: PiSessionState, hasImages: Bool) -> PiReply {
        guard session.state == .known(.waitingForUser) else { return .message(modes(for: session, hasImages: hasImages)) }
        guard let question = session.question, question.isAnswerable else { return .unanswerable }
        return question.kind == .known(.text) ? .answer(question) : .answerAbove
    }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: "直接发送"
        case .steer: "马上说"
        case .followUp: "等它做完再说"
        case .paste: "放进输入框"
        case .answer: "作答"
        case .ping: "连接测试"
        case .start: "新会话"
        case .transcript: "补写对话"
        case .config: "模型与思考强度"
        }
    }

    /// 方式是什么意思，用直白的话（按钮上只写短名）。
    var explanation: String? {
        switch self {
        case .steer: "它做完手上这一步就会看到"
        case .followUp: "这一轮结束后再送达"
        case .paste: "只放进输入框，不发送"
        case .send, .answer, .ping, .start, .transcript, .config: nil
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
