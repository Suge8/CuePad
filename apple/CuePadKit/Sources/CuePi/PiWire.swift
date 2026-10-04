#if os(macOS)
import Foundation

/// 桥协议的线上格式：一行一个 JSON。扩展端见 `Extension/cuepad-bridge.ts`。
enum PiWire {
    /// 客户端支持的协议版本；hello 不同版本一律拒绝
    static let protocolVersion = 1

    struct State: Decodable {
        var kind: String
        var tool: String?
        var tools: [String]?
        var detail: String?
        var promptKind: String?
        var title: String?
        var error: String?
        var aborted: Bool?
        /// 进入该状态的时间（毫秒）
        var since: Double

        var agentState: PiAgentState? {
            switch kind {
            case "idle": .idle
            case "thinking": .thinking
            case "outputting": .outputting
            case "tool": .tool(name: tool ?? "?", running: tools ?? [], detail: detail)
            case "waiting_user": .waitingUser(kind: promptKind, title: title)
            case "done": .done(aborted: aborted ?? false)
            case "error": .error(message: error ?? "")
            default: nil
            }
        }

        var sinceDate: Date { Date(timeIntervalSince1970: since / 1000) }
    }

    struct Hello: Decodable {
        var protocolVersion: Int
        var extensionVersion: Int
        var sessionId: String
        var sessionFile: String?
        var pid: Int32
        var cwd: String
        var mode: String
        var model: String?
        var tty: String?
        var term: [String: String]
        var state: State
        /// 与 `info` 消息同样的字段，平铺在 hello 里
        var name: String?
        var firstMessage: String?
        var lastPrompt: String?
        var lastReply: String?
        var question: String?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case extensionVersion, sessionId, sessionFile, pid, cwd, mode, model, tty, term, state
            case name, firstMessage, lastPrompt, lastReply, question
        }

        var info: Info {
            Info(name: name, firstMessage: firstMessage, lastPrompt: lastPrompt, lastReply: lastReply, question: question)
        }
    }

    /// 会话名、首条用户消息（扩展 v3 起）与近况（v4 起）；旧扩展没有的为 nil。
    struct Info: Decodable {
        var name: String?
        var firstMessage: String?
        var lastPrompt: String?
        var lastReply: String?
        var question: String?

        func apply(to session: inout PiSession) {
            session.name = name
            session.firstMessage = firstMessage
            session.lastPrompt = lastPrompt
            session.lastReply = lastReply
            session.question = question
        }
    }

    struct Ack: Decodable {
        var id: String?
        var ok: Bool
        var delivered: String?
        var error: String?
    }

    struct Bye: Decodable { var reason: String }
    struct StateMessage: Decodable { var state: State }

    enum Message {
        case hello(Hello)
        case state(State)
        case info(Info)
        case ack(Ack)
        case bye(reason: String)
    }

    enum DecodeError: Error { case unknownType(String) }

    static func decode(_ line: Data) throws -> Message {
        struct Envelope: Decodable { var t: String }
        let decoder = JSONDecoder()
        switch try decoder.decode(Envelope.self, from: line).t {
        case "hello": return .hello(try decoder.decode(Hello.self, from: line))
        case "state": return .state(try decoder.decode(StateMessage.self, from: line).state)
        case "info": return .info(try decoder.decode(Info.self, from: line))
        case "ack": return .ack(try decoder.decode(Ack.self, from: line))
        case "bye": return .bye(reason: try decoder.decode(Bye.self, from: line).reason)
        case let other: throw DecodeError.unknownType(other)
        }
    }

    // MARK: CuePad → 扩展

    private struct Command: Encodable {
        struct Image: Encodable { var mimeType: String; var data: String }
        var t: String
        var id: String
        var text: String
        var images: [Image]?
        var deliverAs: String?
    }

    static func sendCommand(id: String, _ message: PiMessage) throws -> Data {
        try encode(Command(
            t: "send", id: id, text: message.text,
            images: message.images.isEmpty ? nil : message.images.map { .init(mimeType: $0.mimeType, data: $0.data.base64EncodedString()) },
            deliverAs: message.whenBusy?.rawValue))
    }

    static func pasteCommand(id: String, text: String) throws -> Data {
        try encode(Command(t: "paste", id: id, text: text))
    }

    private static func encode(_ command: Command) throws -> Data {
        try JSONEncoder().encode(command) + Data([0x0A])
    }
}
#endif
