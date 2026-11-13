import CueStore
import Foundation

/// 同一个去处按用户发起顺序落库，附件等待也占顺序；失败不阻塞后一句，上传不占队列。
final class SendOrder {
    private var tails: [SendingTarget: Task<Void, Never>] = [:]

    func enqueue(_ key: SendingTarget, work: @escaping () async throws -> UUID) -> Task<UUID, Error> {
        let before = tails[key]
        let next = Task { _ = await before?.value; return try await work() }
        tails[key] = Task { _ = await next.result }
        return next
    }
}

extension AppServices {
    func recordSpeech(_ stored: String, to listener: Listener) async throws -> UUID {
        switch listener {
        case .cue:
            return try await store.addCueMessage(.you, text: stored).id
        case .session(let target, let host, let mode, let card):
            try await requireAwake(host)
            if let session = target.ref, mode == .send {
                return try await store.speak(stored, to: session, name: target.name, card: card, host: host).id
            }
            return try await store.requestDelivery(stored, to: target, on: host, mode: mode, card: card).id
        }
    }

    #if os(macOS)
    func recordVoiceSpeech(_ text: String, command: UUID = UUID(), host: String? = nil) async throws -> UUID {
        let recording = sendOrder.enqueue(Listener.cue.orderKey) {
            try await self.store.recordVoiceRequest(StoredBody.make(text: text, files: []), command: command, host: host).id
        }
        return try await recording.value
    }
    #endif
}
