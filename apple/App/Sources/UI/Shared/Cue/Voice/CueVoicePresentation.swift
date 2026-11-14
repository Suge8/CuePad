import CueStore
import SwiftUI

enum CueVoiceActivity {
    case idle, connecting, listening, processing, speaking, closing, failed, ended

    var title: LocalizedStringResource {
        switch self {
        case .idle: "和 Cue 通话"
        case .connecting: "正在连接…"
        case .listening: "我在听"
        case .processing: "等待回应"
        case .speaking: "正在回应"
        case .failed: "通话未连接"
        case .closing: "正在结束…"
        case .ended: "通话已结束"
        }
    }
}

/// 通话界面发出的一个动作，Mac 与手机同一份（`Workspace.performVoice`）。命令带原记录的身份，结果原样返回，不自动重发。
enum VoiceAction: Equatable {
    case start, hangUp, microphoneSettings
    case setMuted(Bool)
    case recover(VoiceRequestReference)
    case repeatReply(UUID)
    case stop(TurnTarget)

    var title: LocalizedStringResource {
        switch self {
        case .start: "重新接通"
        case .hangUp: "挂断"
        case .setMuted: "静音"
        case .recover: "重新交给 Cue"
        case .repeatReply: "再说一遍"
        case .stop: "停止执行"
        case .microphoneSettings: "设置"
        }
    }
}

/// 通话的只读渲染输入：由投影推一次（`VoiceViewState.presentation`），不推进状态、不计时、不推断送达。
/// 高频音量只在声音叶子读取，空样本不伪造声音。
struct CueVoicePresentation {
    typealias Activity = CueVoiceActivity

    struct Issue: Identifiable {
        enum ID: Hashable { case request(VoiceRequestReference), store, connection }
        let id: ID
        let summary: LocalizedStringResource
        let message: LocalizedStringResource
        let recovery: VoiceAction?
    }

    let activity: Activity
    let muted: Bool
    /// 只在声音叶子读取；构造业务投影不观察高频音轨样本。
    let samples: () -> [CGFloat]
    let canMute: Bool
    let issues: [Issue]
    var executions: [Execution] = []
    var readings: [Reading] = []
    /// 手机只收到最近的条目时，其余在哪（`VoiceCallProjection.bounded`）
    var earlier: LocalizedStringResource?
    /// nil 表示允许发起；宿主提供权限、账号或运行设备的实际阻塞原因，视图不推断可用性。
    var startUnavailableReason: LocalizedStringResource?

    /// 只给辨认结果的短摘录；完整正文仍在原聊天，朗读记录不参与错误灯。
    struct Reading: Identifiable {
        let id: UUID
        let excerpt: String
        let status: String
        let recovery: VoiceAction?

        /// 正文第一行的纯文字：朗读记录里不露 Markdown 标记。
        static func excerpt(of text: String) -> String { String((MarkdownBlock.firstPlainLine(text) ?? text).prefix(80)) }
    }

    struct Execution: Identifiable {
        let id: String
        let title: String
        let status: String
        /// 只表示提示强度；执行与停止的生命周期仍由来源记录决定。
        var needsAttention = false
        /// 投影给的那一轮；不把“当前会话”重新解释成按钮原来指的那一轮。
        var stop: VoiceAction?
    }

    var active: Bool { activity != .idle && activity != .ended && activity != .failed }
    var needsAttention: Bool { !issues.isEmpty || executions.contains(where: \.needsAttention) }
    /// 通话详情里有东西可看：通话中，或留着问题、记录与执行。
    var hasDetails: Bool { active || !issues.isEmpty || !readings.isEmpty || !executions.isEmpty }

    var title: LocalizedStringResource {
        muted && activity == .listening ? "麦克风已静音" : activity.title
    }
}

extension VoiceCallProjection.Omitted {
    var shown: LocalizedStringResource? {
        let count = requests + replies + executions
        return count == 0 ? nil : "另有 \(count) 条较早的记录在 Mac 的通话详情里"
    }
}
