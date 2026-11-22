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

enum VoiceAction: Equatable {
    case start, hangUp, microphoneSettings
    case setMuted(Bool)
    case recover(VoiceRequestReference)
    case repeatReply(UUID)

    var title: LocalizedStringResource {
        switch self {
        case .start: "重新接通"
        case .hangUp: "挂断"
        case .setMuted: "静音"
        case .recover: "重新交给 Cue"
        case .repeatReply: "再说一遍"
        case .microphoneSettings: "设置"
        }
    }
}

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
    let samples: () -> [CGFloat]
    let canMute: Bool
    let issues: [Issue]
    var readings: [Reading] = []
    var earlier: LocalizedStringResource?
    var startUnavailableReason: LocalizedStringResource?

    struct Reading: Identifiable {
        let id: UUID
        let excerpt: String
        let status: String
        let recovery: VoiceAction?

        static func excerpt(of text: String) -> String { String((MarkdownBlock.firstPlainLine(text) ?? text).prefix(80)) }
    }

    var active: Bool { activity != .idle && activity != .ended && activity != .failed }
    var needsAttention: Bool { !issues.isEmpty }
    var hasDetails: Bool { active || !issues.isEmpty || !readings.isEmpty }

    var title: LocalizedStringResource {
        muted && activity == .listening ? "麦克风已静音" : activity.title
    }
}

extension VoiceCallProjection.Omitted {
    var shown: LocalizedStringResource? {
        let count = requests + replies
        return count == 0 ? nil : "另有 \(count) 条较早的记录在 Mac 的通话详情里"
    }
}
