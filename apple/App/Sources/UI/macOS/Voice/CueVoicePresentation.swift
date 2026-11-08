#if os(macOS)
import CueStore
import SwiftUI

/// 通话界面的只读投影，由集成层从唯一的通话与 Cue 执行状态生成；这里不推进状态、不计时、不推断送达。
/// 音量是当前实际输入或输出的归一化样本（0…1，旧到新）；无样本传空数组。
/// 请求只有收到 Cue 的持久化确认才显示接走。结束通话不等于停止执行，两种操作始终分开。
struct CueVoicePresentation {
    enum Activity {
        case connecting, listening, processing, speaking, closing, failed, ended

        var title: LocalizedStringResource {
            switch self {
            case .connecting: "正在连接…"
            case .listening: "我在听"
            case .processing: "正在处理"
            case .speaking: "正在说"
            case .failed: "通话未连接"
            case .closing: "正在结束…"
            case .ended: "通话已结束"
            }
        }

        var isLive: Bool { self != .failed && self != .ended && self != .closing }
    }

    struct Request {
        let text: String
        let delivery: Speech.Trip

        var status: String {
            switch delivery {
            case .sending: PiDelivery.Transit.sending.label
            case .sent: PiDelivery.Transit.sent.label
            case .delivered: String(localized: "已交给 Cue")
            case .preparing(let reason), .unconfirmed(let reason): reason
            case .failed(let failure): failure.text
            }
        }
    }

    struct Reply: Identifiable {
        let id: UUID
        let text: String
        let canRequestRepeat: Bool
        var request: Request? = nil
        var note: String? = nil
    }

    enum Recovery: Equatable {
        case retryRequest(String), reconnect

        var title: LocalizedStringResource {
            switch self {
            case .retryRequest: "重新交给 Cue"
            case .reconnect: "重新接通"
            }
        }
    }

    struct Issue {
        let summary: LocalizedStringResource
        let message: LocalizedStringResource
        let recovery: Recovery?
    }

    let name: String
    let activity: Activity
    let muted: Bool
    /// 只在声音叶子读取；构造业务投影不观察高频音轨样本。
    let samples: () -> [CGFloat]
    let request: Request?
    let replies: [Reply]
    let issue: Issue?
    let canStopExecution: Bool
    var executions: [Execution] = []

    struct Execution: Identifiable {
        let id: String
        let title: String
        let status: String
        /// 只表示提示强度；执行与停止的生命周期仍由来源记录决定。
        var needsAttention: Bool = false
    }

    var title: LocalizedStringResource {
        muted && activity == .listening ? "麦克风已静音" : activity.title
    }
}

/// 动作只向宿主发意图；按钮是否可用、静音是否成功、停止执行是否完成均等下一份真实投影。
enum CueVoiceAction {
    case start, toggleMute, hangUp, stopExecution, recover(CueVoicePresentation.Recovery), requestRepeat(UUID), expand, collapse
}
#endif
