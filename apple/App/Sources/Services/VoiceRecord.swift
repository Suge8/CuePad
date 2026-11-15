#if os(macOS)
import CueStore
import CueText
import Foundation
import Observation

/// 语音交出的请求、Cue 的结果与停止请求：通话只往里加、按它朗读，挂断不改它；库记录是业务的依据，转写和音轨不是。
/// 写库不归通话所有：挂断不能撤销可能已落库的业务，也不能丢掉晚回来的请求 ID。
@Observable final class VoiceRecord {
    struct Request: Identifiable {
        enum Submission { case recording, recorded(UUID), returned(UUID), failed(String) }
        let rowID = UUID()
        let delegation: VoiceWire.Delegation
        let origin: VoiceSessionID
        fileprivate(set) var submission: Submission = .recording
        var id: String { delegation.id }
        var text: String { delegation.text }
        var message: UUID? {
            switch submission {
            case .recording, .failed: nil
            case .recorded(let id), .returned(let id): id
            }
        }
        var failure: String? { if case .failed(let reason) = submission { reason } else { nil } }
        var pending: Bool {
            switch submission {
            case .recording, .recorded: true
            case .returned, .failed: false
            }
        }
        var isRecording: Bool { if case .recording = submission { true } else { false } }
    }

    /// 结果先进入界面，再尝试交给语音。没有任何状态声称这条结果已朗读，音轨事件不修改它。
    struct Reply: Identifiable {
        enum Delivery: Equatable {
            case awaitingOrigin, queued, sending, submitted
            case unconfirmed(String)
        }
        let message: CueMessage
        let text: String
        fileprivate(set) var delivery: Delivery
        var id: UUID { message.id }

        fileprivate init(message: CueMessage, delivery: Delivery = .queued) {
            self.message = message
            text = CueFormat.parse(message.text).map(\.shownText).joined()
            self.delivery = delivery
        }
    }

    private(set) var requests: [Request] = []
    private(set) var replies: [Reply] = []
    private(set) var storeFailure: String?
    @ObservationIgnored let store: CueStore
    /// 写一条请求进库；第二个参数是这次写入的身份，同一身份再写不重复（`CueStore.recordVoiceRequest`）。
    @ObservationIgnored var tell: (String, UUID) async throws -> UUID
    /// 正通着的那一通：写完、读到新结果时让它接着朗读，库读不了时让它结束。
    @ObservationIgnored weak var call: VoiceCall?
    @ObservationIgnored private var writing: [String: Task<Error?, Never>] = [:]
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private var latest = 0

    init(store: CueStore, tell: @escaping (String, UUID) async throws -> UUID) {
        self.store = store
        self.tell = tell
    }

    isolated deinit {
        observing?.cancel()
        reading?.cancel()
    }

    var isWriting: Bool { !writing.isEmpty }

    /// 通话开始时定下从哪条消息之后读结果，并订阅库的写入。
    func begin() throws {
        cursor = try store.snapshot { try $0.lastWrite() }.value
        watch()
    }

    /// delegation 可早于 turn.done；直接交正文，身份在结果返回后也保留，重复事件不会再写请求。
    @discardableResult
    func submit(_ delegation: VoiceWire.Delegation, origin: VoiceSessionID) -> Bool {
        guard !requests.contains(where: { $0.id == delegation.id }),
              !delegation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        requests.append(Request(delegation: delegation, origin: origin))
        write(delegation.id, command: UUID())
        return true
    }

    /// 重新交出一条没能写进库的请求（按原行身份认，不收客户端给的正文）；command 让同一次点击重复送达时只写一次。
    /// 没有这一行、已写进库或正在写时返回 nil；写不进抛出原错误。
    func retry(_ rowID: UUID, origin: VoiceSessionID, command: UUID) async throws -> UUID? {
        guard let row = requests.first(where: { $0.rowID == rowID && $0.origin == origin }),
              row.message == nil, row.failure != nil, writing[row.id] == nil else { return nil }
        if let error = await write(row.id, command: command).value { throw error }
        return requests.first { $0.rowID == rowID }?.message
    }

    /// 原请求在库里被重新唤醒（`CueStore.recoverCueMessage`）后，这一行回到等结果。
    func recovered(_ message: UUID) {
        guard let index = requests.firstIndex(where: { $0.message == message }) else { return }
        requests[index].submission = .recorded(message)
    }

    @discardableResult
    private func write(_ id: String, command: UUID) -> Task<Error?, Never> {
        let index = requests.firstIndex { $0.id == id }!
        let text = requests[index].text, tell = tell
        requests[index].submission = .recording
        let task = Task { [self] () -> Error? in
            var failure: Error?
            do {
                let message = try await tell(text, command)
                if let index = requests.firstIndex(where: { $0.id == id }) { requests[index].submission = .recorded(message) }
            } catch {
                failure = error
                VoiceCall.log.error("voice request not recorded: \(error, privacy: .public)")
                if let index = requests.firstIndex(where: { $0.id == id }) { requests[index].submission = .failed(error.localizedDescription) }
            }
            writing[id] = nil
            readMessages()
            call?.drain()
            return failure
        }
        writing[id] = task
        return task
    }

    /// 写入序号只负责读完整份结果，不为了界面更新而触发重复播报。
    private func watch() {
        observing?.cancel()
        let store = store
        let read: @Sendable (isolated CueStore) throws -> Int = { try $0.lastWrite() }
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

    private func update(_ end: Int) {
        storeFailure = nil
        latest = max(latest, end)
        readMessages()
    }

    private func storeFailed(_ error: Error) {
        storeFailure = error.localizedDescription
        call?.fail(.other(error.localizedDescription))
    }

    private func readMessages() {
        guard reading == nil, writing.isEmpty, let cursor, latest > cursor else { return }
        reading = Task { [weak self, store] in
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
                call?.withdraw(message.id)
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
        call?.drain()
    }

    private func acceptsReadback(_ message: CueMessage) -> Bool {
        let answered = Set(message.answeredRequests ?? [])
        return message.author == .known(.cue) && !message.text.isEmpty
            && (answered.isEmpty || requests.contains { $0.message.map(answered.contains) == true })
    }

    /// 明确重说与自动朗读遵循同一来源规则；订阅只负责展示，操作授权必须同步读取权威记录。查询与排队之间没有 await。
    func requeue(_ id: UUID) throws -> VoiceCommandResult.Outcome {
        guard let index = replies.firstIndex(where: { $0.id == id }),
              let original = try store.snapshot({ try $0.cueMessages([id]).first }).value,
              acceptsReadback(original) else { return .rejected(reason: .originalMissing) }
        guard replies[index].delivery != .sending, replies[index].delivery != .queued else {
            return .rejected(reason: .unavailable)
        }
        let reply = Reply(message: original, delivery: .queued)
        guard !reply.text.isEmpty else { return .rejected(reason: .originalMissing) }
        replies[index] = reply
        return .readbackQueued(message: id)
    }

    /// 下一条排着的结果交给语音：标成正在提交，带上它回答的、这一通派出的那条委派（没有就当会话里的一句）。
    func takeQueued(delegations: Set<String>) -> (message: UUID, delegation: String?, text: String)? {
        guard !isWriting, let index = replies.firstIndex(where: { $0.delivery == .queued }) else { return nil }
        let message = replies[index].message
        let answered = Set(message.answeredRequests ?? [])
        let delegation = requests.last { $0.message.map(answered.contains) == true && delegations.contains($0.id) }?.id
        replies[index].delivery = .sending
        return (message.id, delegation, replies[index].text)
    }

    func submitted(_ message: UUID) {
        if let index = replies.firstIndex(where: { $0.id == message }) { replies[index].delivery = .submitted }
    }

    /// 已提交本就不保证播放成功，正常挂断不制造异常；半途取消的发送才需明确请求再说。
    func interrupted() {
        for index in replies.indices where replies[index].delivery == .sending {
            replies[index].delivery = .unconfirmed(String(localized: "朗读尚未确认"))
        }
    }
}
#endif
