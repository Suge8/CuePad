import SwiftUI

/// 共享视图只需要动作的显示名；操作值由平台携带原始带类型引用，不编码正文或重建目标。
protocol CueVoiceOperation {
    var title: LocalizedStringResource { get }
}

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

enum CueVoiceRecovery: Equatable, CueVoiceOperation {
    case retryRequest(String), repeatReply(UUID), reconnect

    var title: LocalizedStringResource {
        switch self {
        case .retryRequest: "重新交给 Cue"
        case .repeatReply: "再说一遍"
        case .reconnect: "重新接通"
        }
    }
}

/// 通话的只读渲染输入：平台直接投影一次，不推进状态、不计时、不推断送达。
/// Operation 保留宿主的带类型动作；高频音量只在声音叶子读取，空样本不伪造声音。
struct CueVoiceState<Operation: CueVoiceOperation> {
    typealias Activity = CueVoiceActivity
    typealias Recovery = Operation

    struct Issue: Identifiable {
        enum ID: Hashable { case request(AnyHashable), store, connection }
        let id: ID
        let summary: LocalizedStringResource
        let message: LocalizedStringResource
        let recovery: Recovery?
    }

    let activity: Activity
    let muted: Bool
    /// 只在声音叶子读取；构造业务投影不观察高频音轨样本。
    let samples: () -> [CGFloat]
    let canMute: Bool
    let issues: [Issue]
    let canStopExecution: Bool
    var executions: [Execution] = []
    var readings: [Reading] = []
    /// 宿主持有各类分页与加载状态；共享按钮原样回传一次批读意图。
    var loadMore: Operation? = nil
    /// nil 表示允许发起；宿主提供权限、账号或运行设备的实际阻塞原因，视图不推断可用性。
    var startUnavailableReason: LocalizedStringResource?

    /// 只给辨认结果的短摘录；完整正文仍在原聊天，朗读记录不参与错误灯。
    struct Reading: Identifiable {
        let id: UUID
        let excerpt: String
        let status: String
        let recovery: Recovery?
    }

    struct Execution: Identifiable {
        let id: String
        let title: String
        let status: String
        /// 只表示提示强度；执行与停止的生命周期仍由来源记录决定。
        var needsAttention: Bool = false
        /// 平台已冻结的精确停止目标；不把“当前会话”重新解释成按钮原来指的那一轮。
        var stop: Operation?
    }

    var active: Bool { activity != .idle && activity != .ended && activity != .failed }
    var needsAttention: Bool { !issues.isEmpty || executions.contains(where: \.needsAttention) }

    var title: LocalizedStringResource {
        muted && activity == .listening ? "麦克风已静音" : activity.title
    }
}

/// 动作只向宿主发意图；按钮是否可用、静音是否成功、停止执行是否完成均等下一份真实投影。
typealias CueVoicePresentation = CueVoiceState<CueVoiceRecovery>
typealias CueVoiceAction = CueVoiceIntent<CueVoiceRecovery>

enum CueVoiceIntent<Operation: CueVoiceOperation> {
    case toggleMute, hangUp, stopExecution, perform(Operation)
}
