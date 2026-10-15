import CueStore
import CueSync
import Foundation

/// "发到 Mac"的界面规则：回复框的按钮、停止与命令的进度。请求本身经 `Workspace.speak` 写出。
nonisolated enum MacDelivery {}

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

/// 回复框主按钮此刻是哪一种（`MacDelivery.button`）。
nonisolated enum PiReplyButton: Equatable {
    case stop
    case answer
    /// 点按（⌘↩）用 `tap`，长按（⌘⇧↩）用 `hold`；只有一种说法时两者相同。
    case send(tap: DeliveryMode, hold: DeliveryMode)
}

extension MacDelivery {
    /// 会话能做什么只看 `AgentCapabilities`：发送方式、能否停止、结束与作答都经 `PiSessionState` 上同一组规则（Cue 也经它们）。

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

        func text(sync: SyncStatus) -> String {
            switch self {
            case .running(let command): "正在执行 \(command)…"
            case .failed(let command, let failure): "\(command) 没执行成功：\(failure.text(sync: sync))"
            }
        }
    }

    static func commandProgress(_ deliveries: [DeliveryRequest], messages: [PiChatMessage], at moment: Speech.Moment) -> CommandProgress? {
        // 最新的一条是按写下的先后排的最后一条（`deliveryRequests(toSession:)`）：时间只到毫秒，同一毫秒的两条按时间比不出先后
        guard let latest = deliveries.last, latest.mode == .known(.command) else { return nil }
        let command = String(latest.content.prefix { !$0.isWhitespace })
        switch Speech.trip(latest, at: moment) {
        case .sending: return .running(command)
        case .delivered: return nil
        case .failed(let failure):
            let failedAt = latest.completedAt ?? latest.modifiedAt
            return messages.contains { $0.at > failedAt } ? nil : .failed(command: command, failure: failure)
        }
    }

    /// 回复框的主按钮（一颗，按状态切换；iOS 与 Mac 同一条）：空着而 Agent 自己在跑一轮是停止（这时最可能想做的就是叫停，同 ChatGPT、Claude），
    /// 文字型问题是作答，其余是发送——点按（⌘↩）是第一种说法，长按（⌘⇧↩）是第二种：在跑时点按等它做完再说、长按马上说，
    /// 没在跑时两种都是直接发送；斜杠命令不分（由 Pi 展开执行）。写了字就是发送：想补充或改方向时停止反而打断，停止仍在长按菜单里。
    /// 选择、确认型问题与发不了的会话没有主按钮（回复框收成一行说明）。
    static func button(for session: PiSessionState, hasDraft: Bool, command: Bool = false) -> PiReplyButton? {
        switch reply(to: session) {
        case .answer: return .answer
        case .message(let modes):
            if session.canStop, !hasDraft { return .stop }
            if command { return .send(tap: .command, hold: .command) }
            return .send(tap: modes[0], hold: modes.dropFirst().first ?? modes[0])
        case .answerAbove, .unanswerable, .restartPi: return nil
        }
    }

    static func reply(to session: PiSessionState) -> PiReply {
        guard session.state != .known(.incompatible) else { return .restartPi }
        guard session.state == .known(.waitingForUser) else { return .message(session.deliveryModes) }
        guard let question = session.answerableQuestion else { return .unanswerable }
        return question.acceptsText ? .answer(question) : .answerAbove
    }
}

nonisolated extension PiSessionState {
    /// 从 CuePad 能用的斜杠命令：做得到时是它报的清单，做不到时没有（输入 "/" 不弹面板，按普通文字发）。
    func usableCommands(in catalog: AgentCatalog?) -> [PiSlashCommand] { capabilities.contains(.commands) ? catalog?.commands ?? [] : [] }
}

extension PiSessionState {
    /// 输入框能带的：做得到时带图片，卡片总能带（发出去是文字）。
    var composerKinds: ComposerKinds { capabilities.contains(.images) ? [.images, .cards, .notes] : [.cards, .notes] }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: "直接发送"
        case .steer: "马上说"
        case .followUp: "等它做完再说"
        case .command: "斜杠命令"
        case .answer: "作答"
        case .ping: "连接测试"
        case .start: "新会话"
        case .transcript: "补写对话"
        case .config: "模型与思考强度"
        case .end: "结束会话"
        case .stop: "停止这一轮"
        case .bind: "绑定文件夹"
        case .quota: "刷新额度"
        }
    }

    /// 方式是什么意思，用直白的话（按钮上只写短名）。
    var explanation: String? {
        switch self {
        case .steer: "它做完手上这一步就会看到"
        case .followUp: "这一轮结束后再送达"
        case .send, .command, .answer, .ping, .start, .transcript, .config, .end, .stop, .bind, .quota: nil
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
