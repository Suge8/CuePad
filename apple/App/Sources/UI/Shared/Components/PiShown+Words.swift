import CueStore
import Foundation

nonisolated extension PiShown {
    var label: String {
        switch status {
        case .delivery(.inTransit(let transit)): transit.label
        case .delivery(.delivered): String(localized: "已送达")
        case .delivery(.failed): String(localized: "没能送达")
        case .working(.tool): String(localized: "运行工具")
        case .working(.delegating): String(localized: "子代理工作中")
        case .working(.compacting): String(localized: "正在压缩上下文")
        case .working: speaking ? String(localized: "输出中") : CueNow.thinking
        case .asking: asksForWords ? String(localized: "等你回答") : String(localized: "等你确认")
        case .awaitsReply: String(localized: "待回复")
        case .cueAsking: String(localized: "等 \(cue ?? "") 回答")
        case .failed: String(localized: "出错")
        case .unread: String(localized: "有新回复")
        case .idle: String(localized: "该你了")
        case .resting: String(localized: "歇着")
        case .fresh: String(localized: "新开的会话")
        case .ended: String(localized: "已结束")
        case .interrupted: String(localized: "被打断")
        case .unknown: String(localized: "未知状态")
        }
    }

    /// 只有一个状态标时它说的是什么（读屏标签、悬停提示、项目长按菜单的标题、任务上的会话状态）。
    var presence: String {
        switch status {
        case .delivery(.inTransit(.waking)): String(localized: "正在唤醒 Agent")
        case .delivery(.failed): String(localized: "没能送达 Agent")
        case .delivery: String(localized: "正在发给 Agent")
        case .working(.compacting): String(localized: "Agent 正在压缩上下文")
        case .working: String(localized: "Agent 正在工作")
        case .asking: asksForWords ? String(localized: "Agent 等你回答") : String(localized: "Agent 等你确认")
        case .awaitsReply: String(localized: "Agent 在等你回复")
        case .cueAsking: String(localized: "Agent 在等 \(cue ?? "") 回答")
        case .failed: String(localized: "Agent 出错")
        case .unread: String(localized: "Agent 有新回复")
        case .idle: String(localized: "Agent 在等你说下一句")
        case .resting: String(localized: "Agent 歇着")
        case .fresh: String(localized: "Agent 新会话")
        case .ended: String(localized: "Agent 会话已结束")
        case .interrupted: String(localized: "Agent 被打断")
        case .unknown: String(localized: "Agent 状态未知")
        }
    }

    /// 名字与状态词加粗：做完了你还没看。
    var isUnread: Bool { status == .unread }

    /// 此刻显示为没能送达时的原因（会话行、项目"此刻"、任务浮窗写它）。
    var undelivered: Speech.Failure? { if case .delivery(.failed(let failure)) = status { failure } else { nil } }

    /// 在跑：工作中，或话在路上、已送达而会话还没跟上（没能送达的不算）——状态色、动效、排序与区头"N 个在跑"同一档。
    var isRunning: Bool {
        switch status {
        case .working, .delivery(.inTransit), .delivery(.delivered): true
        default: false
        }
    }

    /// 会话列表的档：等你确认 → 待回复 → 出错与没能送达 → 工作中与话在路上 → 停下的 → 已结束。拍板在前同看板的等你列（在问的会话卡着 Agent），
    /// 待回复紧随（Cue 页的待回复提示点进来看的就是它们）。
    var rank: Int {
        switch status {
        case .asking: 0
        case .awaitsReply: 1
        case .failed, .delivery(.failed): 2
        case .working, .delivery, .cueAsking: 3
        case .unread, .idle, .resting, .fresh, .interrupted, .unknown: 4
        case .ended: 5
        }
    }

    /// 选会话时排在前面的（发给 Agent 的会话选单）：等你确认与待回复 → 出错 → 有新回复 → 工作中 → 停下的 → 已结束。
    var urgency: Int {
        switch status {
        case .asking, .awaitsReply: 6
        case .failed, .delivery(.failed): 5
        case .unread: 4
        case .working, .delivery, .cueAsking: 2
        case .idle, .resting, .fresh, .interrupted, .unknown: 1
        case .ended: 0
        }
    }
}

nonisolated extension PiShown {
    /// 要你动手：等你确认、待回复、出错、没能送达。只有它们带彩色。
    var needsYou: Bool {
        switch status {
        case .asking, .awaitsReply, .failed, .delivery(.failed): true
        default: false
        }
    }
}
