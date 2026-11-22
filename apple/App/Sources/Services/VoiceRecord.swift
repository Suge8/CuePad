#if os(macOS)
import CueStore
import CueText
import Foundation
import Observation

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
    @ObservationIgnored var tell: (String, UUID) async throws -> UUID
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

    func begin() throws {
        cursor = try store.snapshot { try $0.lastWrite() }.value
        watch()
    }

    @discardableResult
    func submit(_ delegation: VoiceWire.Delegation, origin: VoiceSessionID) -> Bool {
        guard !requests.contains(where: { $0.id == delegation.id }),
              !delegation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        requests.append(Request(delegation: delegation, origin: origin))
        write(delegation.id, command: UUID())
        return true
    }

    func retry(_ rowID: UUID, origin: VoiceSessionID, command: UUID) async throws -> UUID? {
        guard let row = requests.first(where: { $0.rowID == rowID && $0.origin == origin }),
              row.message == nil, row.failure != nil, writing[row.id] == nil else { return nil }
        if let error = await write(row.id, command: command).value { throw error }
        return requests.first { $0.rowID == rowID }?.message
    }

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

    func interrupted() {
        for index in replies.indices where replies[index].delivery == .sending {
            replies[index].delivery = .unconfirmed(String(localized: "朗读尚未确认"))
        }
    }
}
#endif
