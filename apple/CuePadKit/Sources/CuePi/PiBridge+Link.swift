#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

extension PiBridge {
    /// 一条已连接的 Pi socket 及其未完成的命令。
    final class Link: SessionLink {
        let connection: PiSocketConnection
        /// 连上时的那个 socket 文件
        let file: PiSocketDirectory.FileIdentity
        weak var bridge: PiBridge?
        /// 收到 hello 之后的会话
        var id: PiSession.ID?
        /// hello 里报的扩展版本（协议号不同的不读）
        var extensionVersion: Int?
        let replies = PendingReplies<String, PiWire.Ack>(timeout: AgentTimeouts.ack, timeoutError: PiBridgeError.ackTimeout)
        var nextCommand = 0
        var bye: PiWire.Bye?
        var rejected = false
        var exitWatcher: ProcessExitWatcher?
        init(connection: PiSocketConnection, file: PiSocketDirectory.FileIdentity, bridge: PiBridge) {
            self.connection = connection
            self.file = file
            self.bridge = bridge
        }

        var session: PiSession? { id.flatMap { bridge?.session(id: $0) } }

        func send(_ message: PiMessage, in _: PiSession.ID) async throws { _ = try await request { try PiWire.sendCommand(id: $0, message) } }

        func command(_ line: String, in _: PiSession.ID) async throws { _ = try await request { try PiWire.slashCommand(id: $0, line: line) } }

        func reload() async throws { _ = try await request { try PiWire.bare("reload", id: $0) } }

        /// 托管的 SIGTERM 请 Pi 收尾（扩展先发 bye），过了 `endGrace` 还在桥上（连接没断，pid 仍是它）就强杀；
        /// 终端里开的经扩展走 Pi 的正常退出（终端恢复原样）。
        func end(_: PiSession.ID) async throws {
            guard let session else { throw PiBridgeError.sessionEnded }
            guard session.hosted else { return _ = try await request { try PiWire.bare("end", id: $0) } }
            kill(session.pid, SIGTERM)
            Task { [weak self] in
                try? await Task.sleep(for: AgentTimeouts.endGrace)
                if self?.session?.pid == session.pid { kill(session.pid, SIGKILL) }
            }
        }

        func abort(_: PiSession.ID) async throws { _ = try await request { try PiWire.bare("abort", id: $0) } }

        func answer(_ answer: PiAnswerValue, to promptID: String, in _: PiSession.ID) async throws {
            _ = try await request { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
        }

        /// 强度先在这里按目标模型夹好（`PiThinkingLevel.clamped`）：Pi 自己的夹法与之不同，界面按这一条显示。
        func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in _: PiSession.ID) async throws {
            let key = model ?? session?.model?.key
            let levels = session?.availableModels.first { $0.key == key }?.thinkingLevels ?? []
            let thinking = thinking?.clamped(to: levels)
            _ = try await request { try PiWire.configCommand(id: $0, model: model, thinking: thinking, name: name) }
        }

        func refreshQuota() async throws { _ = try await request { try PiWire.bare("quota", id: $0) } }

        private func request(encode: (String) throws -> Data) async throws -> PiWire.Ack {
            guard let session else { throw PiBridgeError.sessionEnded }
            guard !session.upgrading else { throw PiBridgeError.upgradingExtension }
            nextCommand += 1
            let commandID = "c\(nextCommand)"
            let data = try encode(commandID)
            let ack = try await replies.request(commandID) { connection.write(data) }
            guard ack.ok else { throw ack.error == "unknown_model" ? PiBridgeError.unknownModel(.pi) : PiBridgeError.rejected(ack.error ?? "unknown") }
            return ack
        }
    }

    /// 连着的 Pi 会话都报了这个扩展版本（还没 hello 的、协议号不同的都不算）：过渡时判断旧单文件扩展还有没有会话在用
    /// （`AgentIntegration.retireLegacyPiExtension`）。连接在扫描 socket 目录时同步建立，所以已在跑的会话都算在内。
    public func allRun(extensionVersion version: Int) -> Bool { links.values.allSatisfy { $0.extensionVersion == version } }
}
#endif
