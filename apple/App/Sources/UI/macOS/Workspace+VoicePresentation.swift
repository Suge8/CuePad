#if os(macOS)
import CueStore
import SwiftUI

extension Workspace {
    private static let voiceRequestExcerptLimit = 24
    /// 只投影已有事实：每条请求保留自己的位置，回复按持久化的来源归组，合批回复列出全部来源。
    /// 没有关联来源的是主动消息；不把最后一次请求套到更早的回复上。
    var voicePresentation: CueVoicePresentation? {
        guard let voice else { return nil }
        let activity: CueVoicePresentation.Activity = switch voice.phase {
        case .connecting: .connecting
        case .listening: .listening
        case .handingOff: .processing
        case .speaking: .speaking
        case .closing: .closing
        case .ended: .ended
        case .failed: .failed
        }
        return CueVoicePresentation(
            name: cue.name, activity: activity, muted: voice.isMuted, samples: { voice.samples.map { CGFloat($0) } }, request: voice.requests.last.map(voiceRequest),
            replies: voiceRows(voice), issue: voiceIssue(voice), canStopExecution: !stoppableVoiceExecutions.isEmpty,
            executions: voiceExecutions.map {
                let shown = shownInHeader($0.state, delivery: nil)
                let attention: Bool = switch shown.status {
                case .unknown: true
                default: shown.needsYou
                }
                return .init(id: $0.state.sessionID, title: $0.task?.title ?? $0.state.title,
                             status: shown.label, needsAttention: attention)
            } + voice.stopRequests.map(voiceStopExecution))
    }

    var stoppableVoiceExecutions: [PiSessionListItem] {
        voiceExecutions.filter { $0.state.canStop && !voiceStopping($0) }
    }

    private func voiceStopping(_ execution: PiSessionListItem) -> Bool {
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

    var voiceIssueRequest: VoiceCall.Request? {
        voice?.requests.first { request in
            if request.failure != nil { return true }
            guard request.pending, let record = request.record else { return false }
            return Speech.trip(said: record.createdAt, delivered: record.deliveredAt, reachedServer: record.reachedServer,
                               host: cue.hostID, at: services.speech).unconfirmedReason != nil
        }
    }

    private func voiceIssue(_ voice: VoiceCall) -> CueVoicePresentation.Issue? {
        if let request = voiceIssueRequest {
            let reason = request.failure ?? voiceRequest(request).delivery.unconfirmedReason ?? Speech.unconfirmedReason.text
            let excerpt = String(request.text.prefix(Self.voiceRequestExcerptLimit))
            let summary: LocalizedStringResource = request.failure != nil ? "未能交给 Cue：\(excerpt)" : "送达未确认：\(excerpt)"
            return .init(summary: summary, message: "请求「\(request.text)」：\(reason)", recovery: request.failure != nil ? .retryRequest(request.id) : nil)
        }
        if let failure = voice.storeFailure { return .init(summary: "通话记录暂不可用", message: "\(failure)", recovery: .reconnect) }
        switch voice.phase {
        case .failed(let failure): return .init(summary: "通话未连接", message: "\(failure.shown)", recovery: .reconnect)
        default: return nil
        }
    }

    private func voiceRows(_ voice: VoiceCall) -> [CueVoicePresentation.Reply] {
        let order = Dictionary(uniqueKeysWithValues: voice.requests.enumerated().compactMap { index, request in
            request.message.map { ($0, index) }
        })
        var groups: [String: [CueVoicePresentation.Reply]] = [:]
        var standalone: [CueVoicePresentation.Reply] = []
        for reply in voice.replies {
            let sources = (reply.message.answeredRequests ?? []).compactMap { order[$0] }.sorted().map { voice.requests[$0] }
            var row = voiceReply(reply, call: voice)
            if sources.count > 1 {
                let pending = sources.map(voiceRequest).first { $0.delivery != .delivered }
                row.request = .init(text: sources.map(\.text).joined(separator: "\n\n"), delivery: pending?.delivery ?? .delivered)
            }
            if let request = sources.last { groups[request.id, default: []].append(row) }
            else { standalone.append(row) }
        }
        return voice.requests.flatMap { request in
            [.init(id: request.rowID, text: "", canRequestRepeat: false, request: voiceRequest(request))] + (groups[request.id] ?? [])
        } + standalone
    }

    private func voiceRequest(_ request: VoiceCall.Request) -> CueVoicePresentation.Request {
        let delivery: Speech.Trip
        if let failure = request.failure { delivery = .failed(.reported(failure)) }
        else if let record = request.record { delivery = Said.cue(record, host: cue.hostID).trip(at: services.speech) }
        else { delivery = .sending }
        return .init(text: request.text, delivery: delivery)
    }

    private func voiceReply(_ reply: VoiceCall.Reply, call: VoiceCall) -> CueVoicePresentation.Reply {
        let note: String? = switch reply.delivery {
        case .awaitingOrigin: String(localized: "这条结果尚未关联到通话请求，可以查看文字或点再说一遍")
        case .queued, .sending, .submitted: nil
        case .unconfirmed(let reason): reason
        }
        return .init(id: reply.id, text: reply.text,
                     canRequestRepeat: call.canRepeat && reply.delivery != .sending, note: note)
    }
}
#endif
