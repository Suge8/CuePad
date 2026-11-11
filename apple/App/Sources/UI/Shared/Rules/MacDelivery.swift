import CueStore
import CueSync
import Foundation


/// 选择、确认型问题要先在上面作答：自由文本发出去会一直挂着，Pi 不答完题不会去看。
nonisolated enum ReplyMode: Equatable {
    case message
    case answer(Question)
    case answerAbove
    case unanswerable
}

nonisolated enum ReplyButton: Equatable {
    case stop
    case answer
    case send(DeliveryMode)
}

/// 能否停止、结束与作答都经 `SessionState` 上同一组规则（Cue 也经它们）。
nonisolated enum MacDelivery {
    /// 记录 ended 不确认投送；未知请求逐条保留，不能被别的结束成功掩盖。新的结束在途时先显示它的进度。
    static func endIssue(_ requests: [DeliveryRequest], at moment: Speech.Moment) -> Speech.Trip? {
        let ends = requests.filter { $0.mode == .known(.end) }.map { Speech.trip($0, at: moment) }
        guard !ends.contains(where: \.awaitingResult) else { return nil }
        if let unknown = ends.last(where: { $0.unconfirmedReason != nil }) { return unknown }
        return ends.last.flatMap { $0.failure != nil ? $0 : nil }
    }

    /// 受理只表示收到，歇下看状态。进度只读投送请求，界面不另存。
    static func stopping(_ session: SessionState, deliveries: [DeliveryRequest], at moment: Speech.Moment) -> Bool {
        guard session.canStop, let turnStart = session.busySince else { return false }
        return deliveries.contains { request in
            guard [.known(.stop), .known(.stopTurn)].contains(request.mode), request.createdAt >= turnStart else { return false }
            let trip = Speech.trip(request, at: moment)
            return trip.inTransit || trip == .delivered
        }
    }

    /// 读投送请求与对话，不另存。
    enum CommandProgress: Equatable {
        case preparing(String)
        case running(String)
        case unconfirmed(command: String, reason: String)
        case failed(command: String, failure: Speech.Failure)

        var failed: Bool { if case .failed = self { true } else { false } }

        var text: String {
            switch self {
            case .preparing(let reason): reason
            case .running(let command): String(localized: "正在执行 \(command)…")
            case .unconfirmed(let command, let reason): String(localized: "\(command) 的执行结果尚未确认：\(reason)")
            case .failed(let command, let failure): String(localized: "\(command) 没执行成功：\(failure.text)")
            }
        }
    }

    static func commandProgress(_ deliveries: [DeliveryRequest], messages: [ChatMessage], at moment: Speech.Moment) -> CommandProgress? {
        // 最新的一条是按写下的先后排的最后一条（`deliveryRequests(toSession:)`）：时间只到毫秒，同一毫秒的两条按时间比不出先后
        guard let latest = deliveries.last, latest.mode == .known(.command) else { return nil }
        let command = String(latest.content.prefix { !$0.isWhitespace })
        let trip = Speech.trip(latest, at: moment)
        if trip.failure != nil || trip.unconfirmedReason != nil {
            let finished = latest.completedAt ?? Speech.deadline(latest) ?? latest.modifiedAt
            if messages.contains(where: { $0.at > finished }) { return nil }
        }
        switch trip {
        case .preparing(let reason): return .preparing(reason)
        case .sending, .sent: return .running(command)
        case .delivered: return nil
        case .unconfirmed(let reason): return .unconfirmed(command: command, reason: reason)
        case .failed(let failure): return .failed(command: command, failure: failure)
        }
    }

    /// 空着而 Agent 自己在跑一轮是停止：这时最可能想做的就是叫停（同 ChatGPT、Claude）。
    static func button(for session: SessionState, hasDraft: Bool, command: Bool = false) -> ReplyButton? {
        switch reply(to: session) {
        case .answer: return .answer
        case .message:
            if session.canStop, !hasDraft { return .stop }
            return .send(command ? .command : .send)
        case .answerAbove, .unanswerable: return nil
        }
    }

    static func reply(to session: SessionState) -> ReplyMode {
        guard session.state == .known(.waitingForUser) else { return .message }
        guard let question = session.answerableQuestion else { return .unanswerable }
        return question.acceptsText ? .answer(question) : .answerAbove
    }
}

nonisolated extension SessionState {
    /// 做不到时没有：输入 "/" 不弹面板，按普通文字发。
    func usableCommands(in catalog: AgentCatalog?) -> [SlashCommand] { catalog?.commands ?? [] }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: String(localized: "说话")
        case .withdraw: String(localized: "撤回")
        case .command: String(localized: "斜杠命令")
        case .answer: String(localized: "作答")
        case .start: String(localized: "新会话")
        case .transcript: String(localized: "补写对话")
        case .config: String(localized: "模型与思考强度")
        case .end: String(localized: "结束会话")
        case .stop, .stopTurn: String(localized: "停止这一轮")
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
