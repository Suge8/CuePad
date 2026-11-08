#if os(macOS)
import CueStore
import Foundation

extension VoiceCall {
    /// delegation 可早于 turn.done；直接交正文，身份在结果返回后也保留，重复事件不会再写请求。
    func submit(_ delegation: VoiceWire.Delegation) {
        guard !requestState.contains(where: { $0.id == delegation.id }),
              !delegation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestState.append(Request(delegation: delegation, origin: VoiceSessionID(session)))
        delegations.insert(delegation.id)
        mark("handoff \(delegation.id)")
        recordRequest(delegation.id)
    }

    /// 写库不归媒体连接所有：挂断不能撤销可能已落库的业务，也不能丢掉晚回来的请求 ID。
    func recordRequest(_ id: String) {
        guard let index = requestState.firstIndex(where: { $0.id == id }), writing[id] == nil else { return }
        let text = requestState[index].text, tell = dependencies.tell
        requestState[index].submission = .recording
        requestState[index].record = nil
        writing[id] = Task { [self] in
            do {
                let message = try await tell(text)
                if let index = requestState.firstIndex(where: { $0.id == id }) { requestState[index].submission = .recorded(message) }
                watchRequests()
            } catch {
                if let index = requestState.firstIndex(where: { $0.id == id }) { requestState[index].submission = .failed(error.localizedDescription) }
            }
            writing[id] = nil
            readMessages()
            drain()
        }
    }

    nonisolated struct Read: Equatable, Sendable {
        let end: Int
        let requests: [CueMessage]
        let executions: [PiSessionListItem]
        let stops: [DeliveryRequest]
    }

    /// 写入序号只负责读完整份结果；送达字段另外订阅原记录，不为了界面更新而触发重复播报。
    func watchRequests() {
        observing?.cancel()
        let ids = requestState.compactMap(\.message), stops = stopRequests.map(\.id), store = dependencies.store
        let read: @Sendable (isolated CueStore) throws -> Read = { store in
            try Read(end: store.lastWrite(), requests: store.cueMessages(ids), executions: store.voiceExecutions(requests: ids),
                     stops: stops.compactMap { try store.deliveryRequest($0) })
        }
        do {
            let start = try store.snapshot(read)
            update(start.value)
            observing = Task { [weak self] in
                do {
                    for try await read in store.observe(from: start, read) {
                        guard !Task.isCancelled else { return }
                        self?.update(read)
                    }
                } catch { if !Task.isCancelled { self?.storeFailed(error) } }
            }
        } catch { storeFailed(error) }
    }

    private func update(_ read: Read) {
        storeFailure = nil
        executionState = read.executions
        for stop in read.stops {
            if let index = stopRequests.firstIndex(where: { $0.id == stop.id }) { stopRequests[index] = stop }
        }
        for index in requestState.indices {
            requestState[index].record = read.requests.first { $0.id == requestState[index].message }
        }
        latest = max(latest, read.end)
        readMessages()
    }

    private func storeFailed(_ error: Error) {
        storeFailure = error.localizedDescription
        if isLive { inputs.continuation.yield(.failed(.other(error.localizedDescription))) }
    }

    private func readMessages() {
        guard reading == nil, writing.isEmpty, let cursor, latest > cursor else { return }
        reading = Task { [weak self, store = dependencies.store] in
            do {
                let page = try await store.cueMessagePage(after: cursor)
                guard !Task.isCancelled else { return }
                self?.received(page)
            } catch {
                self?.reading = nil
                if !Task.isCancelled { self?.storeFailed(error) }
            }
        }
    }

    private func received(_ page: CueMessagePage) {
        reading = nil
        guard writing.isEmpty else { return }
        for entry in page.entries {
            let message = entry.message
            let answered = Set(message.answeredRequests ?? [])
            for index in requestState.indices {
                if let id = requestState[index].message, answered.contains(id) { requestState[index].submission = .returned(id) }
            }
            guard message.author == .known(.cue), !message.text.isEmpty,
                  answered.isEmpty || requestState.contains(where: { $0.message.map(answered.contains) == true }) else {
                if outgoing?.message == message.id { outgoing?.task.cancel(); outgoing = nil }
                replyState.removeAll { $0.id == message.id }
                continue
            }
            let proposed = Reply(message: message, delivery: message.answeredRequests == nil ? .awaitingOrigin : .queued)
            if let index = replyState.firstIndex(where: { $0.id == message.id }) {
                let previous = replyState[index].delivery
                replyState[index] = Reply(message: message, delivery: previous == .awaitingOrigin ? proposed.delivery : previous)
            } else {
                var reply = proposed
                if reply.text.isEmpty { reply.delivery = .unconfirmed(String(localized: "这份回复没有可朗读的文字")) }
                replyState.append(reply)
            }
        }
        cursor = page.through
        readMessages()
        drain()
    }

    /// 同一条结果只在明确操作后重说；正文仍取真实记录，不重新派活，也不把旧交接 ID 带进新连接。
    func repeatReply(_ id: UUID) {
        guard canRepeat, let index = replyState.firstIndex(where: { $0.id == id }), replyState[index].delivery != .sending,
              !replyState[index].text.isEmpty else { return }
        replyState[index].delivery = .queued
        drain()
    }

    /// 可见结果与传输分开推进。send 结束只记本机提交；异步服务端错误仍会使已提交结果变为未确认。
    func drain() {
        guard let channel, outgoing == nil, writing.isEmpty,
              let index = replyState.firstIndex(where: { $0.delivery == .queued }) else { return }
        let message = replyState[index].message
        let answered = Set(message.answeredRequests ?? [])
        let delegation = requestState.last { $0.message.map(answered.contains) == true && delegations.contains($0.id) }?.id
        let text = replyState[index].text
        replyState[index].delivery = .sending
        let outgoingMessage: VoiceWire.Outgoing = delegation.map { .reply(delegation: $0, text: text) } ?? .say(text)
        let attempt = UUID()
        let task = Task { [inputs, mark] in
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(Speech.sendLimit)); inputs.continuation.yield(.sent(attempt, .timedOut)) }
                catch { }
            }
            defer { timeout.cancel() }
            do {
                mark("cue-forward \(message.id) delegation=\(delegation ?? "session") \(text)")
                try await channel.send(outgoingMessage)
                try Task.checkCancellation()
                inputs.continuation.yield(.sent(attempt, nil))
            } catch {
                if !Task.isCancelled { inputs.continuation.yield(.sent(attempt, .closed(error.localizedDescription))) }
            }
        }
        outgoing = (attempt, message.id, task)
    }
}
#endif
