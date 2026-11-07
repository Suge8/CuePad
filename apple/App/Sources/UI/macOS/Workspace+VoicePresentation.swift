#if os(macOS)
import CueStore
import SwiftUI

extension Workspace {
    /// 只投影已有事实：每条请求保留自己的位置，回复按持久化的来源归组，合批回复列出全部来源。
    /// 没有关联来源的是主动消息；不把最后一次请求套到更早的回复上。
    var voicePresentation: CueVoicePresentation? {
        guard let voice else { return nil }
        let activity: CueVoicePresentation.Activity = switch voice.phase {
        case .connecting: .connecting
        case .listening: .listening
        case .handingOff: .processing
        case .speaking: .speaking
        case .ended: .ended
        case .failed: .failed
        }
        return CueVoicePresentation(
            name: cue.name, activity: activity, muted: voice.isMuted, samples: { voice.samples.map { CGFloat($0) } }, request: nil,
            replies: voiceRows(voice), issue: voiceIssue(voice), canStopExecution: !stoppableVoiceExecutions.isEmpty,
            executions: voiceExecutions.map {
                .init(id: $0.state.sessionID, title: $0.task?.title ?? $0.state.title,
                      status: voiceExecutionStatus($0))
            })
    }

    var stoppableVoiceExecutions: [PiSessionListItem] {
        voiceExecutions.filter { $0.state.canStop && !voiceStopping($0) }
    }

    private func voiceStopping(_ execution: PiSessionListItem) -> Bool {
        MacDelivery.stopping(execution.state, deliveries: [execution.delivery].compactMap(\.self), at: services.speech)
    }

    private func voiceExecutionStatus(_ execution: PiSessionListItem) -> String {
        if voiceStopping(execution) { return String(localized: "正在停止…") }
        if let request = execution.delivery, [.known(.stop), .known(.stopTurn)].contains(request.mode) {
            let trip = Speech.trip(request, at: services.speech)
            if let reason = trip.unconfirmedReason { return reason }
            if let failure = trip.failure { return failure.text }
        }
        return shownInHeader(execution.state, delivery: execution.delivery).label
    }

    var voiceRetryRequest: VoiceCall.Request? {
        voice?.requests.first { request in
            if request.failure != nil { return true }
            guard request.pending, let record = request.record else { return false }
            return Speech.trip(said: record.createdAt, delivered: record.deliveredAt, reachedServer: record.reachedServer,
                               host: cue.hostID, at: services.speech).unconfirmedReason != nil
        }
    }

    private func voiceIssue(_ voice: VoiceCall) -> CueVoicePresentation.Issue? {
        if let request = voiceRetryRequest {
            return .init(message: "\(request.failure ?? Speech.unconfirmedReason.text)", recovery: "重新交给 Cue")
        }
        if let failure = voice.storeFailure { return .init(message: "\(failure)", recovery: "重新接通") }
        switch voice.phase {
        case .failed(let failure): return .init(message: "\(failure.shown)", recovery: "重新接通")
        case .ended: return .init(message: "请求和结果仍保留在这里", recovery: "重新接通")
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
