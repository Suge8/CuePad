import CueStore
import Foundation

nonisolated extension SessionShown {
    var label: String {
        switch status {
        case .delivery(.preparing(let reason)): reason
        case .delivery(.inTransit(let transit)): transit.label
        case .delivery(.delivered): String(localized: "已送达")
        case .delivery(.failed): String(localized: "没能送达")
        case .working(.tool): String(localized: "运行工具")
        case .working(.delegating): String(localized: "子代理工作中")
        case .working(.compacting): String(localized: "正在压缩上下文")
        case .working: speaking ? String(localized: "输出中") : CueNow.thinking
        case .asking: asksForWords ? String(localized: "等你回答") : String(localized: "等你确认")
        case .awaitsReply, .unread: String(localized: "新回复")
        case .cueAsking: String(localized: "等 \(cue ?? "") 回答")
        case .failed(.network): String(localized: "连不上")
        case .failed(.quota): String(localized: "达到用量限制")
        case .failed(.login): String(localized: "登录失效")
        case .failed(.other): String(localized: "出错")
        case .failed(.truncated): String(localized: "回答未完成")
        case .idle, .resting: String(localized: "空闲")
        case .fresh: String(localized: "新开的会话")
        case .ended: String(localized: "已结束")
        case .interrupted: String(localized: "被打断")
        case .unknown(let mac?): String(localized: "「\(mac)」没开")
        case .unknown: String(localized: "状态未确认")
        }
    }

    var presence: String {
        switch status {
        case .delivery(.preparing(let reason)): reason
        case .delivery(.inTransit(.unconfirmed)): String(localized: "送达未确认")
        case .delivery(.inTransit(.waking)): String(localized: "正在唤醒 Agent")
        case .delivery(.failed): String(localized: "没能送达 Agent")
        case .delivery: String(localized: "正在发给 Agent")
        case .working(.compacting): String(localized: "Agent 正在压缩上下文")
        case .working: String(localized: "Agent 正在工作")
        case .asking: asksForWords ? String(localized: "Agent 等你回答") : String(localized: "Agent 等你确认")
        case .awaitsReply: String(localized: "Agent 有新回复，留给你回")
        case .cueAsking: String(localized: "Agent 在等 \(cue ?? "") 回答")
        case .failed: String(localized: "Agent 出错")
        case .unread: String(localized: "Agent 有新回复")
        case .idle, .resting: String(localized: "Agent 空闲")
        case .fresh: String(localized: "Agent 新会话")
        case .ended: String(localized: "Agent 会话已结束")
        case .interrupted: String(localized: "Agent 被打断")
        case .unknown(let mac?): String(localized: "「\(mac)」没开")
        case .unknown: String(localized: "Agent 状态尚未确认")
        }
    }

    /// 新回复（没看的与 Cue 留给你回的同一个样子）：名字加粗、整行着回复的淡绿。
    var isNewReply: Bool { status == .unread || status == .awaitsReply }

    /// 空闲：做完了、没有要你看的。不画状态标、不写状态字，只留多久以前。
    var isQuiet: Bool { status == .idle || status == .resting }

    var undelivered: Speech.Failure? { if case .delivery(.failed(let failure)) = status { failure } else { nil } }

    var isRunning: Bool {
        switch status {
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): false
        case .working, .delivery(.inTransit), .delivery(.delivered): true
        default: false
        }
    }

    /// 拍板在前同看板的等你列（在问的会话卡着 Agent），待回复紧随。
    var rank: Int {
        switch status {
        case .asking: 0
        case .awaitsReply: 1
        case .failed, .delivery(.failed): 2
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): 4
        case .working, .delivery, .cueAsking: 3
        case .unread, .idle, .resting, .fresh, .interrupted, .unknown: 4
        case .ended: 5
        }
    }

    var urgency: Int {
        switch status {
        case .asking, .awaitsReply: 6
        case .failed, .delivery(.failed): 5
        case .unread: 4
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): 1
        case .working, .delivery, .cueAsking: 2
        case .idle, .resting, .fresh, .interrupted, .unknown: 1
        case .ended: 0
        }
    }
}

nonisolated extension SessionShown {
    var needsYou: Bool {
        switch status {
        case .asking, .awaitsReply, .failed, .delivery(.failed): true
        default: false
        }
    }
}
