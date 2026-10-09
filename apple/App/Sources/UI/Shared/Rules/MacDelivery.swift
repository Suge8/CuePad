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
    /// 会话在跑旧版扩展（`PiWorkState.incompatible`），发不进去
    case restartPi
}

extension MacDelivery {
    /// 能结束：在线，且读得到（旧版扩展的会话收不到结束命令，要在终端里退出 Pi）。
    static func canEnd(_ session: PiSessionState) -> Bool { session.state != .known(.ended) && session.state != .known(.incompatible) }

    /// 回复框给不给"停止"：指挥官自己在跑一轮、没在等你时；等你确认时它在等你答（停止会让人以为把问题也撤了），
    /// 等子代理时这一轮已经歇下，都没有可停的。
    static func canStop(_ session: PiSessionState) -> Bool {
        session.state.known?.isTurnRunning == true && session.state != .known(.waitingForUser)
    }

    /// 正在停止：这一轮开始后发过停止请求，它还在路上或 Mac 已受理，而这一轮还没歇下（受理只表示收到，歇下看状态）。
    /// 进度只读投送请求，界面不另存。
    static func stopping(_ session: PiSessionState, deliveries: [DeliveryRequest]) -> Bool {
        guard canStop(session) else { return false }
        let turnStart = session.busySince ?? session.stateSince
        return deliveries.contains { request in
            request.mode == .known(.stop) && request.createdAt >= turnStart
                && (request.isOpen || request.status == .known(.succeeded))
        }
    }

    /// 斜杠命令的进度（读投送请求，不另存）：只看最近一条命令——在路上写"正在执行 /compact…"、没成功写原因、成功就消失
    /// （命令不进对话、不进发送记录；结果若在会话文件里，对话里自然有）。回复框上方一行显示。
    enum CommandProgress: Equatable {
        case running(String)
        case failed(command: String, reason: String)

        var failed: Bool { if case .failed = self { true } else { false } }

        var text: String {
            switch self {
            case .running(let command): "正在执行 \(command)…"
            case .failed(let command, let reason): "\(command) 没执行成功：\(reason)"
            }
        }
    }

    static func commandProgress(_ deliveries: [DeliveryRequest]) -> CommandProgress? {
        guard let latest = deliveries.last(where: { $0.mode == .known(.command) }) else { return nil }
        let command = String(latest.content.prefix { !$0.isWhitespace })
        if let failure = latest.failure { return .failed(command: command, reason: failure) }
        return latest.isOpen ? .running(command) : nil
    }

    static func reply(to session: PiSessionState, hasImages: Bool) -> PiReply {
        guard session.state != .known(.incompatible) else { return .restartPi }
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
        case .command: "斜杠命令"
        case .answer: "作答"
        case .ping: "连接测试"
        case .start: "新会话"
        case .transcript: "补写对话"
        case .config: "模型与思考强度"
        case .end: "结束会话"
        case .stop: "停止这一轮"
        case .bind: "绑定文件夹"
        }
    }

    /// 方式是什么意思，用直白的话（按钮上只写短名）。
    var explanation: String? {
        switch self {
        case .steer: "它做完手上这一步就会看到"
        case .followUp: "这一轮结束后再送达"
        case .paste: "只放进输入框，不发送"
        case .send, .command, .answer, .ping, .start, .transcript, .config, .end, .stop, .bind: nil
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
