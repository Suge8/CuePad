#if os(macOS)
import CueStore
import Foundation

@MainActor
final class PiConnection: SessionLink {
    let connection: SocketConnection
    let file: SocketDirectory.FileIdentity
    weak var bridge: Bridge?
    var id: Session.ID?
    let replies: PendingReplies<String, PiWire.Ack>
    var nextCommand = 0
    var bye: PiWire.Bye?
    var rejected = false
    var exitWatcher: ProcessExitWatcher?
    init(connection: SocketConnection, file: SocketDirectory.FileIdentity, bridge: Bridge) {
        self.connection = connection
        self.file = file
        self.bridge = bridge
        replies = PendingReplies(timeout: AgentTimeouts.ack, timing: bridge.timing, timeoutError: BridgeError.ackTimeout)
    }

    var session: Session? { id.flatMap { bridge?.session(id: $0) } }

    func send(_ message: SessionMessage, in _: Session.ID) async throws { _ = try await request { try PiWire.sendCommand(id: $0, message) } }

    func command(_ line: String, opener _: TurnOpener?, in _: Session.ID) async throws { _ = try await request { try PiWire.slashCommand(id: $0, line: line) } }

    func end(_: Session.ID) async throws { _ = try await request { try PiWire.bare("end", id: $0) } }

    func abort(_: Session.ID) async throws { _ = try await request { try PiWire.bare("abort", id: $0) } }

    func retry(_: Session.ID) async throws { _ = try await request { try PiWire.bare("retry", id: $0) } }

    func answer(_ answer: AnswerValue, to promptID: String, in _: Session.ID) async throws {
        _ = try await request { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
    }

    func configure(_ config: SessionConfig, in _: Session.ID) async throws {
        let key = config.model ?? session?.model?.key
        let levels = session?.availableModels.first { $0.key == key }?.thinkingLevels ?? []
        let thinking = config.thinking?.clamped(to: levels)
        _ = try await request { try PiWire.configCommand(id: $0, model: config.model, thinking: thinking, fast: config.fast, name: config.name) }
    }

    func offerUpgrade(from version: Int) {
        guard version != PiExtensionBundle.version else { return }
        connection.write(PiWire.upgrade)
    }

    func canNameItself(_: Session.ID) -> Bool { true }

    func suggestName(from firstMessage: String, in _: Session.ID) async throws -> String {
        let ack = try await request { try PiWire.titleCommand(id: $0, text: firstMessage) }
        guard let title = ack.title.flatMap(SessionNameSuggestion.cleaned) else { throw BridgeError.rejected("failed: empty title") }
        return title
    }

    func refreshQuota(in _: Session.ID) async throws { _ = try await request { try PiWire.bare("quota", id: $0) } }

    private func request(encode: (String) throws -> Data) async throws -> PiWire.Ack {
        guard let session else { throw BridgeError.sessionEnded }
        guard !session.upgrading else { throw BridgeError.upgradingExtension }
        nextCommand += 1
        let commandID = "c\(nextCommand)"
        let data = try encode(commandID)
        let ack = try await replies.request(commandID) { connection.write(data) }
        guard !ack.ok else { return ack }
        throw ack.error == "unknown_model" ? BridgeError.unknownModel(.pi) : BridgeError.rejected(ack.error ?? "unknown")
    }
}

#endif
