#if os(macOS)
import CueStore
import SwiftUI

extension Workspace {
    /// 只投影控制所需事实；已落库的请求与回复由原聊天读取，未落库失败保留各自身份。
    var voicePresentation: CueVoicePresentation? {
        guard let voice else { return nil }
        // 媒体阶段优先；接通后的等待和回应来自协议回合，写库与句间电平不推进显示状态。
        let activity: CueVoicePresentation.Activity = switch voice.phase {
        case .connecting: .connecting
        case .listening, .handingOff, .speaking:
            !voice.assistantTurns.isEmpty ? .speaking : voice.waitingForResponse ? .processing : .listening
        case .closing: .closing
        case .ended: .ended
        case .failed: .failed
        }
        return CueVoicePresentation(
            activity: activity, muted: voice.isMuted, samples: { voice.samples.map { CGFloat($0) } }, canMute: voice.canMute,
            issues: voiceIssues(voice), canStopExecution: !stoppableVoiceExecutions.isEmpty,
            executions: voiceExecutions.map {
                let shown = shownInHeader($0.state, delivery: nil)
                let attention: Bool = switch shown.status {
                case .unknown: true
                default: shown.needsYou
                }
                return .init(id: $0.state.sessionID, title: $0.task?.title ?? $0.state.title,
                             status: shown.label, needsAttention: attention)
            } + voice.stopRequests.map(voiceStopExecution),
            readings: voice.replies.map { voiceReading($0, call: voice) })
    }

    var stoppableVoiceExecutions: [SessionListItem] {
        voiceExecutions.filter { $0.state.canStop && !voiceStopping($0) }
    }

    private func voiceStopping(_ execution: SessionListItem) -> Bool {
        MacDelivery.stopping(execution.state, deliveries: [execution.delivery].compactMap(\.self), at: services.speech)
    }

    private func voiceStopExecution(_ request: DeliveryRequest) -> CueVoicePresentation.Execution {
        let (status, attention): (String, Bool) = switch Speech.trip(request, at: services.speech) {
        case .sending, .sent: (String(localized: "正在停止…"), false)
        case .delivered: (String(localized: "停止请求已受理"), false)
        case .preparing(let reason): (reason, false)
        case .unconfirmed(let reason): (reason, true)
        case .failed(let failure): (failure.text, true)
        }
        return .init(id: request.id.uuidString, title: String(localized: "停止「\(request.target.name)」"),
                     status: status, needsAttention: attention)
    }

    private func voiceReading(_ reply: VoiceCall.Reply, call: VoiceCall) -> CueVoicePresentation.Reading {
        let status: String = switch reply.delivery {
        case .awaitingOrigin: String(localized: "结果来源尚未确认")
        case .queued: String(localized: "等待提交语音")
        case .sending: String(localized: "正在提交语音…")
        case .submitted: String(localized: "已提交语音，朗读尚未确认")
        case .unconfirmed(let reason): reason
        }
        let repeatable = call.canRepeat && !reply.text.isEmpty && reply.delivery != .sending && reply.delivery != .queued
        return .init(id: reply.id, excerpt: CueVoicePresentation.Reading.excerpt(of: reply.text), status: status,
                     recovery: repeatable ? .repeatReply(reply.id) : nil)
    }

    private func voiceIssues(_ voice: VoiceCall) -> [CueVoicePresentation.Issue] {
        var issues: [CueVoicePresentation.Issue] = voice.requests.compactMap { request in
            guard request.message == nil, let failure = request.failure else { return nil }
            return .init(id: .request(request.id), summary: "未能交给 Cue", message: "请求「\(request.text)」：\(failure)",
                         recovery: .retryRequest(request.id))
        }
        if let failure = voice.storeFailure {
            issues.append(.init(id: .store, summary: "通话记录暂不可用", message: "\(failure)", recovery: .reconnect))
        }
        if case .failed(let failure) = voice.phase {
            issues.append(.init(id: .connection, summary: "通话未连接", message: "\(failure.shown)", recovery: .reconnect))
        }
        return issues
    }
}
#endif
