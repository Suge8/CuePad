import CueStore
import Foundation

/// 同一个去处按用户发起顺序落库，附件等待也占顺序；失败不阻塞后一句，上传不占队列。
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
    func recordSpeech(_ stored: String, to listener: Listener) async throws {
        switch listener {
        case .cue:
            try await store.addCueMessage(.you, text: stored)
        case .session(let target, let host, let mode, let card):
            try await requireAwake(host)
            if let session = target.ref, mode == .send {
                _ = try await store.speak(stored, to: session, name: target.name, card: card, host: host)
            } else {
                try await store.requestDelivery(stored, to: target, on: host, mode: mode, card: card)
            }
        }
    }

    #if os(macOS)
    func recordVoiceSpeech(_ text: String, command: UUID = UUID(), host: String? = nil) async throws -> UUID {
        let recording = sendOrder.enqueue(Listener.cue.orderKey) { () async -> Result<UUID, Error> in
            do { return .success(try await self.store.recordVoiceRequest(StoredBody.make(text: text, files: []), command: command, host: host).id) }
            catch { return .failure(error) }
        }
        return try await recording.value.get()
    }
    #endif
}
