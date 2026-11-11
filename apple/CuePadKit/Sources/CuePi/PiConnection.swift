#if os(macOS)
import CueStore
import Foundation

@MainActor
final class PiConnection: SessionLink {
    let connection: SocketConnection
    let file: SocketDirectory.FileIdentity
    weak var bridge: Bridge?
    var id: Session.ID?
    var extensionVersion: Int?
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

    func command(_ line: String, deliveryID _: String?, in _: Session.ID) async throws { _ = try await request { try PiWire.slashCommand(id: $0, line: line) } }

    func reload() async throws { _ = try await request { try PiWire.bare("reload", id: $0) } }

    /// 退出方式由扩展按真实 mode 选择，不按 hosted 猜模式，也不对外部 PID 发信号。
    func end(_: Session.ID) async throws { _ = try await request { try PiWire.bare("end", id: $0) } }

    func abort(_: Session.ID) async throws { _ = try await request { try PiWire.bare("abort", id: $0) } }

    func abort(_: Session.ID, deliveryID: String, turnStartedAt: Int64) async throws {
        guard extensionVersion.map({ $0 >= PiWire.abortTurnSince }) == true else {
            throw BridgeError.rejected("upgrade_stop_turn")
        }
        _ = try await request { try PiWire.abortTurnCommand(id: $0, deliveryID: deliveryID, turnStartedAt: turnStartedAt) }
    }

    func retry(_: Session.ID) async throws { _ = try await request { try PiWire.bare("retry", id: $0) } }

    func answer(_ answer: AnswerValue, to promptID: String, in _: Session.ID) async throws {
        _ = try await request { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
    }

    /// 强度按目标模型夹取：Pi 自己的夹法不同，界面按这一条显示。
    func configure(_ config: SessionConfig, in _: Session.ID) async throws {
        let key = config.model ?? session?.model?.key
        let levels = session?.availableModels.first { $0.key == key }?.thinkingLevels ?? []
        let thinking = config.thinking?.clamped(to: levels)
        _ = try await request { try PiWire.configCommand(id: $0, model: config.model, thinking: thinking, fast: config.fast, name: config.name) }
    }

    /// 报的扩展版本不是随包版本（没报的也算）：请它核对磁盘（`PiWire.upgrade`）。磁盘上还是旧的它就不动，所以可以多说。
    func offerUpgrade() {
        guard extensionVersion != PiExtensionBundle.version else { return }
        connection.write(PiWire.upgrade)
    }

    func canNameItself(_: Session.ID) -> Bool { extensionVersion.map { $0 >= PiWire.titleSince } ?? false }

    func suggestName(from firstMessage: String, in _: Session.ID) async throws -> String {
        let ack = try await request { try PiWire.titleCommand(id: $0, text: firstMessage) }
        guard let title = ack.title.flatMap(SessionNameSuggestion.cleaned) else { throw BridgeError.rejected("failed: empty title") }
        return title
    }

    func refreshQuota() async throws { _ = try await request { try PiWire.bare("quota", id: $0) } }

    private func request(encode: (String) throws -> Data) async throws -> PiWire.Ack {
        guard let session else { throw BridgeError.sessionEnded }
        guard !session.upgrading else { throw BridgeError.upgradingExtension }
        nextCommand += 1
        let commandID = "c\(nextCommand)"
        let data = try encode(commandID)
        let ack = try await replies.request(commandID) { connection.write(data) }
        guard !ack.ok else { return ack }
        // 旧扩展不认比它新的命令（`PiWire.oldestExtension`）：换上新扩展后才做得到
        throw ack.error == "unknown_model" ? BridgeError.unknownModel(.pi) : BridgeError.rejected(ack.error ?? "unknown")
    }
}

#endif
