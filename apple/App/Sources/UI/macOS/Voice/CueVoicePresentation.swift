#if os(macOS)
import SwiftUI

/// 通话界面的只读投影，由集成层从唯一的通话与 Cue 执行状态生成；这里不推进状态、不计时、不推断送达。
/// 音量是当前实际输入或输出的归一化样本（0…1，旧到新）；无样本传空数组。
/// 请求只有收到 Cue 的持久化确认才标 accepted。结束通话不等于停止执行，两种操作始终分开。
struct CueVoicePresentation {
    enum Activity {
        case connecting, listening, processing, speaking, failed, ended

        var title: LocalizedStringResource {
            switch self {
            case .connecting: "正在连接…"
            case .listening: "我在听"
            case .processing: "正在处理"
            case .speaking: "正在说"
            case .failed: "通话未连接"
            case .ended: "通话已结束"
            }
        }

        var isLive: Bool { self != .failed && self != .ended }
    }

    struct Request {
        enum Delivery {
            case submitting, accepted, failed
            var title: LocalizedStringResource {
                switch self {
                case .submitting: "正在交给 Cue…"
                case .accepted: "已交给 Cue"
                case .failed: "未交给 Cue"
                }
            }
        }
        let text: String
        let delivery: Delivery
    }

    struct Reply: Identifiable {
        let id: UUID
        let text: String
        let canRequestRepeat: Bool
    }

    struct Issue {
        let message: LocalizedStringResource
        let recovery: LocalizedStringResource
    }

    let name: String
    let activity: Activity
    let muted: Bool
    let samples: [CGFloat]
    let request: Request?
    let replies: [Reply]
    let issue: Issue?
    let canStopExecution: Bool

    var title: LocalizedStringResource {
        muted && activity == .listening ? "麦克风已静音" : activity.title
    }
}

/// 动作只向宿主发意图；按钮是否可用、静音是否成功、停止执行是否完成均等下一份真实投影。
enum CueVoiceAction {
    case start, toggleMute, hangUp, stopExecution, recover, requestRepeat(UUID), expand, collapse
}
#endif
