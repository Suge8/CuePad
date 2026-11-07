#if os(macOS)
import CueStore
import CueText
import Foundation

extension VoiceCall {
    /// delegation 可早于 turn.done；直接交正文，身份在结果返回后也保留，重复事件不会再写请求。
    func submit(_ delegation: VoiceWire.Delegation) {
        guard !requests.contains(where: { $0.delegation.id == delegation.id }),
              !delegation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requests.append(Request(delegation: delegation))
        mark("handoff \(delegation.id)")
        writing[delegation.id] = Task { [tell = dependencies.tell, inputs] in
            do {
                let id = try await tell(delegation.text)
                inputs.continuation.yield(.recorded(delegation: delegation.id, message: id))
            } catch { inputs.continuation.yield(.failed(.other(error.localizedDescription))) }
        }
    }

    /// 读与发共用一个拥有者、一个消费游标；ready 前只积累库的末尾，ready 后按页补齐。
    /// 写库回执先回来才能判断回复归属，避免高速 Cue 回复抢在请求 ID 回到通话之前。
    func drain() {
        guard let channel, outgoing == nil, writing.isEmpty else { return }
        guard let entry = pending.first else {
            guard latest > cursor else { return }
            outgoing = Task { [store = dependencies.store, inputs, cursor] in
                do { inputs.continuation.yield(.loaded(try await store.cueMessagePage(after: cursor))) }
                catch { inputs.continuation.yield(.failed(.other(error.localizedDescription))) }
            }
            return
        }
        let message = entry.message
        let answered = Set(message.answeredRequests ?? [])
        let matched = requests.filter { $0.message.map(answered.contains) == true }
        let text = message.author == .known(.cue) ? CueFormat.parse(message.text).map(\.shownText).joined() : ""
        let outgoingMessage: VoiceWire.Outgoing? = if text.isEmpty { nil }
            else if let delegation = matched.last?.delegation.id { .reply(delegation: delegation, text: text) }
            else { .say(text) }
        outgoing = Task { [inputs, mark] in
            do {
                if let outgoingMessage {
                    mark("cue-forward \(message.id) delegation=\(matched.last?.delegation.id ?? "session") \(text)")
                    try await channel.send(outgoingMessage)
                }
                try Task.checkCancellation()
                inputs.continuation.yield(.sent(sequence: entry.sequence, requests: answered, forwarded: outgoingMessage == nil ? nil : message.id))
            } catch {
                if !Task.isCancelled { inputs.continuation.yield(.failed(.closed(error.localizedDescription))) }
            }
        }
    }
}
#endif
