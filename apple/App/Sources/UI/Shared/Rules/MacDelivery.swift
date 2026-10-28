import CueStore
import CueSync
import Foundation


/// 回复框此刻该做什么：发消息、就是作答框（文字型问题）、
/// 先在上面作答（选择、确认型问题：自由文本发出去会一直挂着，Pi 不答完题不会去看）、这里答不了（只能在 Mac 上答）。
nonisolated enum PiReply: Equatable {
    case message
    case answer(PiQuestion)
    case answerAbove
    case unanswerable
}

/// 回复框主按钮此刻是哪一种（`MacDelivery.button`）。
nonisolated enum PiReplyButton: Equatable {
    case stop
    case answer
    /// 说话（`send`）或斜杠命令（`command`）
    case send(DeliveryMode)
}

/// "发到 Mac"的界面规则：回复框的按钮、停止与命令的进度。请求本身经 `Workspace.speak` 写出。
/// 会话能做什么只看 `AgentCapabilities`：能否停止、结束与作答都经 `PiSessionState` 上同一组规则（Cue 也经它们）。
nonisolated enum MacDelivery {
    /// 正在停止：这一轮开始后发过停止请求，它还在路上或 Mac 已受理，而这一轮还没歇下（受理只表示收到，歇下看状态）。
    /// 进度只读投送请求，界面不另存。
    static func stopping(_ session: PiSessionState, deliveries: [DeliveryRequest], at moment: Speech.Moment) -> Bool {
        guard session.canStop, let turnStart = session.busySince else { return false }
        return deliveries.contains { request in
            request.mode == .known(.stop) && request.createdAt >= turnStart && Speech.trip(request, at: moment).failure == nil
        }
    }

    /// 斜杠命令的进度（读投送请求与对话，不另存）：最近一条请求是命令时才有——在路上写"正在执行 /compact…"、没成功写原因、
    /// 成功就消失（命令不进对话、不进发送记录；结果若在会话文件里，对话里自然有）。失败的在之后有新的请求、对话里多了话时收起。
    /// 回复框上方一行显示。
    enum CommandProgress: Equatable {
        case running(String)
        case failed(command: String, failure: Speech.Failure)

        var failed: Bool { if case .failed = self { true } else { false } }

        var text: String {
            switch self {
            case .running(let command): String(localized: "正在执行 \(command)…")
            case .failed(let command, let failure): String(localized: "\(command) 没执行成功：\(failure.text)")
            }
        }
    }

    static func commandProgress(_ deliveries: [DeliveryRequest], messages: [PiChatMessage], at moment: Speech.Moment) -> CommandProgress? {
        // 最新的一条是按写下的先后排的最后一条（`deliveryRequests(toSession:)`）：时间只到毫秒，同一毫秒的两条按时间比不出先后
        guard let latest = deliveries.last, latest.mode == .known(.command) else { return nil }
        let command = String(latest.content.prefix { !$0.isWhitespace })
        switch Speech.trip(latest, at: moment) {
        case .sending, .sent: return .running(command)
        case .delivered: return nil
        case .failed(let failure):
            let failedAt = latest.completedAt ?? latest.modifiedAt
            return messages.contains { $0.at > failedAt } ? nil : .failed(command: command, failure: failure)
        }
    }

    /// 回复框的主按钮（一颗，按状态切换；iOS 与 Mac 同一条）：空着而 Agent 自己在跑一轮是停止（这时最可能想做的就是叫停，同 ChatGPT、Claude），
    /// 文字型问题是作答，其余是发送（在跑时发出就打断这一轮、以这句开新一轮）；斜杠命令由 Agent 展开执行。
    /// 选择、确认型问题与发不了的会话没有主按钮（回复框收成一行说明）。
    static func button(for session: PiSessionState, hasDraft: Bool, command: Bool = false) -> PiReplyButton? {
        switch reply(to: session) {
        case .answer: return .answer
        case .message:
            if session.canStop, !hasDraft { return .stop }
            return .send(command ? .command : .send)
        case .answerAbove, .unanswerable: return nil
        }
    }

    static func reply(to session: PiSessionState) -> PiReply {
        guard session.state == .known(.waitingForUser) else { return .message }
        guard let question = session.answerableQuestion else { return .unanswerable }
        return question.acceptsText ? .answer(question) : .answerAbove
    }
}

nonisolated extension PiSessionState {
    /// 从 CuePad 能用的斜杠命令：做得到时是它报的清单，做不到时没有（输入 "/" 不弹面板，按普通文字发）。
    func usableCommands(in catalog: AgentCatalog?) -> [PiSlashCommand] { capabilities.contains(.commands) ? catalog?.commands ?? [] : [] }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: String(localized: "说话")
        case .command: String(localized: "斜杠命令")
        case .answer: String(localized: "作答")
        case .start: String(localized: "新会话")
        case .transcript: String(localized: "补写对话")
        case .config: String(localized: "模型与思考强度")
        case .end: String(localized: "结束会话")
        case .stop: String(localized: "停止这一轮")
        case .retry: String(localized: "重试这一轮")
        case .bind: String(localized: "绑定文件夹")
        case .quota: String(localized: "刷新额度")
        case .tidy: String(localized: "整理技能与规则")
        case .libraryEdit: String(localized: "改技能与规则")
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
