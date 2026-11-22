import CueStore
import Foundation

final class SendOrder {
    private var tails: [SendingTarget: Task<Void, Never>] = [:]

    func enqueue<T: Sendable>(_ key: SendingTarget, work: @escaping () async -> T) -> Task<T, Never> {
        let before = tails[key]
        let next = Task { _ = await before?.value; return await work() }
        tails[key] = Task { _ = await next.value }
        return next
    }
}

extension AppServices {
    /// `id` 是这句在库里的编号，按下发送时就定好：飞出去的那句按它认出自己落成的气泡（`SendFlight`）。
    func recordSpeech(_ stored: String, to listener: Listener, as id: UUID) async throws {
        switch listener {
        case .cue:
            try await store.addCueMessage(.you, text: stored, id: id)
        case .session(let target, let host, let mode, let card):
            try await requireAwake(host)
            if let session = target.ref, mode == .send {
                _ = try await store.speak(stored, to: session, name: target.name, card: card, host: host, id: id)
            } else {
                try await store.requestDelivery(stored, to: target, on: host, mode: mode, card: card, id: id)
            }
        }
    }

    #if os(macOS)
    func recordVoiceSpeech(_ text: String, command: UUID, host: String?) async throws -> UUID {
        let recording = sendOrder.enqueue(Listener.cue.orderKey) { () async -> Result<UUID, Error> in
            do { return .success(try await self.store.recordVoiceRequest(StoredBody.make(text: text, files: []), command: command, host: host).id) }
            catch { return .failure(error) }
        }
        return try await recording.value.get()
    }
    #endif
}
