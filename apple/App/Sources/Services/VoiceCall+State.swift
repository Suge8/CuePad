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

    /// 实时模型唯一的一条开发者消息（`initial_items`）：会话的 `instructions` 字段实测不生效（要它只说法语照样说中文、自称 ChatGPT），所以不发。
    /// 委派与播报靠服务端默认行为；往开发者消息里加规则（#105）或任务、灵感标题作背景（#109）都会让英文建任务不再委派并谎称已办好，背景越长越重，不要加。
    static func identity(name: String) -> String {
        """
        You are \(name), the user's assistant in CuePad: you capture the user's ideas, manage their tasks and direct the agents on their Mac. \
        When asked who you are, your name or what you can do, answer as \(name) with this role. \
        Never say you are ChatGPT, OpenAI or any underlying model, and never mention a backend.
        """
    }
}

protocol VoiceControl: AnyObject {
    func send(_ outgoing: VoiceWire.Outgoing) async throws
    func close()
}
#endif
