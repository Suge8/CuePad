#if os(macOS)
import CueStore
import Foundation

extension VoiceCall {
    /// delegation 可早于 turn.done；直接交正文，身份在结果返回后也保留，重复事件不会再写请求。
    func submit(_ delegation: VoiceWire.Delegation) {
        guard !requests.contains(where: { $0.id == delegation.id }),
              !delegation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requests.append(Request(delegation: delegation, origin: VoiceSessionID(session)))
        delegations.insert(delegation.id)
        mark("handoff \(delegation.id)")
        recordRequest(delegation.id)
    }

    /// 写库不归媒体连接所有：挂断不能撤销可能已落库的业务，也不能丢掉晚回来的请求 ID。
    func recordRequest(_ id: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }), writing[id] == nil else { return }
        let text = requests[index].text, tell = dependencies.tell
        requests[index].submission = .recording
        writing[id] = Task { [self] in
            do {
                let message = try await tell(text)
                if let index = requests.firstIndex(where: { $0.id == id }) { requests[index].submission = .recorded(message) }
                watchRequests()
            } catch {
                if let index = requests.firstIndex(where: { $0.id == id }) { requests[index].submission = .failed(error.localizedDescription) }
            }
            writing[id] = nil
            readMessages()
            drain()
        }
    }

    nonisolated struct Read: Equatable, Sendable {
        let end: Int
        let executions: [SessionListItem]
        let stops: [DeliveryRequest]
    }

    /// 写入序号只负责读完整份结果，不为了界面更新而触发重复播报。
    func watchRequests() {
        observing?.cancel()
        let ids = requests.compactMap(\.message), stops = stopRequests.map(\.id), store = dependencies.store
        let read: @Sendable (isolated CueStore) throws -> Read = { store in
            try Read(end: store.lastWrite(), executions: store.voiceExecutions(requests: ids),
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
        executions = read.executions
        for stop in read.stops {
            if let index = stopRequests.firstIndex(where: { $0.id == stop.id }) { stopRequests[index] = stop }
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
            for index in requests.indices {
                if let id = requests[index].message, answered.contains(id) { requests[index].submission = .returned(id) }
            }
            guard acceptsReadback(message) else {
                if outgoing?.message == message.id { outgoing?.task.cancel(); outgoing = nil }
                replies.removeAll { $0.id == message.id }
                continue
            }
            let proposed = Reply(message: message, delivery: message.answeredRequests == nil ? .awaitingOrigin : .queued)
            if let index = replies.firstIndex(where: { $0.id == message.id }) {
                let previous = replies[index].delivery
                replies[index] = Reply(message: message, delivery: previous == .awaitingOrigin ? proposed.delivery : previous)
            } else {
                var reply = proposed
                if reply.text.isEmpty { reply.delivery = .unconfirmed(String(localized: "这份回复没有可朗读的文字")) }
                replies.append(reply)
            }
        }
        cursor = page.through
        readMessages()
        drain()
    }

    private func acceptsReadback(_ message: CueMessage) -> Bool {
        let answered = Set(message.answeredRequests ?? [])
        return message.author == .known(.cue) && !message.text.isEmpty
            && (answered.isEmpty || requests.contains { $0.message.map(answered.contains) == true })
    }

    /// 明确重说与自动朗读遵循同一来源规则；订阅只负责展示，操作授权必须同步读取权威记录。
    /// 查询、原媒体身份校验与排队之间没有 await，不能把旧条目的索引用到另一轮通话。
    func repeatReply(_ id: UUID, mediaSession: VoiceSessionID) throws -> VoiceCommandResult.Outcome {
        guard VoiceSessionID(session) == mediaSession, canRepeat,
              let index = replies.firstIndex(where: { $0.id == id }),
              let original = try dependencies.store.snapshot({ try $0.cueMessages([id]).first }).value,
              acceptsReadback(original) else { return .rejected(reason: .originalMissing) }
        guard replies[index].delivery != .sending, replies[index].delivery != .queued else {
            return .rejected(reason: .unavailable)
        }
        let reply = Reply(message: original, delivery: .queued)
        guard !reply.text.isEmpty else { return .rejected(reason: .originalMissing) }
        replies[index] = reply
        drain()
        return .readbackQueued(message: id)
    }

    /// 可见结果与传输分开推进。send 结束只记本机提交；异步服务端错误仍会使已提交结果变为未确认。
    func drain() {
        guard let channel, outgoing == nil, writing.isEmpty,
              let index = replies.firstIndex(where: { $0.delivery == .queued }) else { return }
        let message = replies[index].message
        let answered = Set(message.answeredRequests ?? [])
        let delegation = requests.last { $0.message.map(answered.contains) == true && delegations.contains($0.id) }?.id
        let text = replies[index].text
        replies[index].delivery = .sending
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
