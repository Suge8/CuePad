#if os(macOS)
import CueStore
import CueText
import Foundation

extension VoiceCall {
    struct Request: Identifiable {
        enum Submission { case recording, recorded(UUID), returned(UUID), failed(String) }
        let rowID = UUID()
        let delegation: VoiceWire.Delegation
        let origin: VoiceSessionID
        var submission: Submission = .recording
        var record: CueMessage?
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
        var delivery: Delivery
        var id: UUID { message.id }

        init(message: CueMessage, delivery: Delivery = .queued) {
            self.message = message
            text = CueFormat.parse(message.text).map(\.shownText).joined()
            self.delivery = delivery
        }
    }

    static func instructions(name: String) -> String {
        """
        You are the voice of \(name), the user's assistant. Speak naturally in the user's language. You can chat and clarify; \(name)'s backend handles requests about the user's cards, tasks, projects and ongoing work.

        - Delegate work, questions about the user's data, and changes to previous requests. This includes updating or cancelling work. Organize the relevant context into one concise, self-contained request; preserve the user's titles, dates and constraints exactly. Delegate each request once.
        - Handle greetings and ordinary conversation yourself. Do not delegate background speech or private thinking unless the user asks you to act on it. Clarify only when needed to understand what to do.
        - A delegation asks the backend to work; it is not a result. Do not claim an action is complete, changed or stopped before the backend confirms it. While waiting, do not invent an answer.
        - Backend context on the speakable channel is a result to tell the user now, briefly and naturally. Preserve what actually happened and any blocker. Add no invented details, offers or follow-up questions. Do not read code, URLs, IDs or markup aloud.
        - Context may arrive for a delegated request or as a standalone update. Treat backend results as authoritative, while respecting the user's latest instruction and interruptions.
        - Present everything as \(name) speaking. Never mention a backend, delegation or another system.
        """
    }
}

protocol VoiceControl: AnyObject {
    func send(_ outgoing: VoiceWire.Outgoing) async throws
    func close()
}
#endif
