import CueStore
import Foundation

extension AppServices {
    func answerRemoteCueQuestion(_ message: UUID, _ choice: String) async throws {
        guard let sync, try await sync.syncNow() != .incomplete else { throw URLError(.cannotLoadFromNetwork) }
        try Task.checkCancellation()
        try await answerCueQuestion(message, choice)
    }

    func answerCueQuestion(_ message: UUID, _ choice: String) async throws { try await endCueQuestion(message, .answered(choice)) }

    func declineCueQuestion(_ message: UUID) async throws { try await endCueQuestion(message, .withdrawn) }

    private func endCueQuestion(_ message: UUID, _ end: CueQuestionEnd) async throws {
        try await store.endCueQuestion(message, end)
        #if os(iOS)
        await resendSnapshots()
        #endif
    }
}
