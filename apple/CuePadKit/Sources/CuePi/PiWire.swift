#if os(macOS)
import Foundation

/// 桥协议的线上格式：一行一个 JSON。扩展端见 `Extension/cuepad-bridge.ts`。
enum PiWire {
    /// 客户端说的协议版本；hello 的版本不同就不往下解析（命令一条不发），会话只当"需要 /reload"（`OtherProtocolHello`）
    static let protocolVersion = 8

    struct State: Decodable {
        var kind: String
        var tool: String?
        var tools: [String]?
        var detail: String?
        var promptKind: String?
        var title: String?
        var error: String?
        var aborted: Bool?
        /// 进入当前粗状态的时间（毫秒）
        var since: Double
        /// 这段连续处理开始的时间（毫秒），空闲、出错时为 nil
        var busySince: Double?

        var agentState: PiAgentState? {
            switch kind {
            case "idle": .idle
            case "thinking": .thinking
            case "outputting": .outputting
            case "tool": .tool(name: tool ?? "?", running: tools ?? [], detail: detail)
            case "delegating": .delegating
            case "waiting_user": .waitingUser(kind: promptKind, title: title)
            case "done": .done(aborted: aborted ?? false)
            case "error": .error(message: error ?? "")
            default: nil
            }
        }

        var sinceDate: Date { Date(timeIntervalSince1970: since / 1000) }
        var busySinceDate: Date? { busySince.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    struct Hello: Decodable {
        var protocolVersion: Int
        var extensionVersion: Int
        var sessionId: String
        var sessionFile: String?
        var pid: Int32
        var cwd: String
        var mode: String
        var tty: String?
        var term: [String: String]
        var state: State
        /// CuePad 开的新会话：启动时经环境变量交给扩展的认领标识（扩展 v8 起；其余会话没有）
        var launchToken: String?
        /// CuePad 在后台托管的 Pi（扩展 v9 起）
        var hosted: Bool?
        /// 与 `info` 消息同样的字段，平铺在 hello 里
        var name: String?
        var firstMessage: String?
        var question: PiPrompt?
        var subagents: [PiSubagent]?
        var model: PiModel?
        var thinking: String?
        var models: [PiModel]?
        var context: PiContext?
        var commands: [PiCommand]?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case extensionVersion, sessionId, sessionFile, pid, cwd, mode, tty, term, state, launchToken, hosted
            case name, firstMessage, question, subagents, model, thinking, models, context, commands
        }

        var info: Info {
            Info(
                name: name, firstMessage: firstMessage, question: question, subagents: subagents, model: model, thinking: thinking, models: models,
                context: context, commands: commands)
        }
    }

    /// 协议版本不同的 hello：格式可能已变，只读认得出会话的几项（其余字段读不出就当没有）。
    struct OtherProtocolHello: Decodable {
        var protocolVersion: Int
        var extensionVersion: Int
        var sessionId: String
        var pid: Int32
        var cwd: String
        var name: String?
        var firstMessage: String?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case extensionVersion, sessionId, pid, cwd, name, firstMessage
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
            extensionVersion = (try? c.decode(Int.self, forKey: .extensionVersion)) ?? 0
            sessionId = try c.decode(String.self, forKey: .sessionId)
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decode(String.self, forKey: .cwd)
            name = try? c.decode(String.self, forKey: .name)
            firstMessage = try? c.decode(String.self, forKey: .firstMessage)
        }
    }

    /// 会话名、首条用户消息（扩展 v3 起）、等你回答的弹窗（v4 起）、子代理（v5 起）、模型配置（协议 v2 起）、上下文余量与命令清单（协议 v5 起）；没有的为 nil。
    /// 问答近况不走这里：对话与摘要只来自会话文件（`PiHistory`）。
    struct Info: Decodable {
        var name: String?
        var firstMessage: String?
        var question: PiPrompt?
        var subagents: [PiSubagent]?
        var model: PiModel?
        var thinking: String?
        var models: [PiModel]?
        var context: PiContext?
        var commands: [PiCommand]?

        func apply(to session: inout PiSession) {
            session.name = name
            session.firstMessage = firstMessage
            session.question = question
            session.subagents = subagents ?? []
            session.model = model
            session.thinking = thinking
            session.availableModels = models ?? []
            session.context = context
            session.commands = commands ?? []
        }
    }

    struct Ack: Decodable {
        var id: String?
        var ok: Bool
        var delivered: String?
        var error: String?
    }

    /// 扩展代 Pi 的 `cuepad_show` 工具调用请 CuePad 收下一个文件作预览（协议 v8 起）；`path` 已是绝对路径
    struct Show: Decodable {
        var id: String
        var path: String
        var title: String?
    }

    struct Bye: Decodable { var reason: String }
    struct StateMessage: Decodable { var state: State }

    enum Message {
        case hello(Hello)
        case otherProtocol(OtherProtocolHello)
        case state(State)
        case info(Info)
        case ack(Ack)
        case show(Show)
        case bye(reason: String)
    }

    enum DecodeError: Error { case unknownType(String) }

    static func decode(_ line: Data) throws -> Message {
        struct Envelope: Decodable { var t: String }
        let decoder = JSONDecoder()
        switch try decoder.decode(Envelope.self, from: line).t {
        case "hello":
            let other = try decoder.decode(OtherProtocolHello.self, from: line)
            return other.protocolVersion == protocolVersion ? .hello(try decoder.decode(Hello.self, from: line)) : .otherProtocol(other)
        case "state": return .state(try decoder.decode(StateMessage.self, from: line).state)
        case "info": return .info(try decoder.decode(Info.self, from: line))
        case "ack": return .ack(try decoder.decode(Ack.self, from: line))
        case "show": return .show(try decoder.decode(Show.self, from: line))
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
        var deliveryId: String?
    }

    static func sendCommand(id: String, _ message: PiMessage) throws -> Data {
        try encode(Command(
            t: "send", id: id, text: message.text,
            images: message.images.isEmpty ? nil : message.images.map { .init(mimeType: $0.mimeType, data: $0.data.base64EncodedString()) },
            deliverAs: message.whenBusy?.rawValue, deliveryId: message.deliveryID))
    }

    /// 斜杠命令：`text` 是以 / 开头的整行；`deliverAs` 只对会被展开成这一轮提示词的模板与 skill 在会话正忙时生效。
    static func slashCommand(id: String, line: String, whenBusy: PiQueueMode?) throws -> Data {
        var command = Command(t: "command", id: id, text: line)
        command.deliverAs = whenBusy?.rawValue
        return try encode(command)
    }

    static func pasteCommand(id: String, text: String) throws -> Data {
        try encode(Command(t: "paste", id: id, text: text))
    }

    private struct ShownReply: Encodable {
        var t = "shown"
        var id: String
        var ok: Bool
        var preview: String?
        var note: String?
        var error: String?
    }

    static func shownReply(id: String, _ result: Result<PiShowReply, any Error>) throws -> Data {
        switch result {
        case .success(let shown): try encodeLine(ShownReply(id: id, ok: true, preview: shown.preview, note: shown.note))
        case .failure(let error): try encodeLine(ShownReply(id: id, ok: false, error: error.localizedDescription))
        }
    }

    private struct ReloadCommand: Encodable {
        var t = "reload"
        var id: String
    }

    static func reloadCommand(id: String) throws -> Data { try encodeLine(ReloadCommand(id: id)) }

    private struct EndCommand: Encodable {
        var t = "end"
        var id: String
    }

    static func endCommand(id: String) throws -> Data { try encodeLine(EndCommand(id: id)) }

    private struct AbortCommand: Encodable {
        var t = "abort"
        var id: String
    }

    static func abortCommand(id: String) throws -> Data { try encodeLine(AbortCommand(id: id)) }

    private struct ConfigCommand: Encodable {
        struct Model: Encodable { var provider: String; var id: String }
        var t = "config"
        var id: String
        var model: Model?
        var thinking: String?
        var name: String?
    }

    static func configCommand(id: String, model: PiModelRef?, thinking: String?, name: String?) throws -> Data {
        try encodeLine(ConfigCommand(id: id, model: model.map { .init(provider: $0.provider, id: $0.id) }, thinking: thinking, name: name))
    }

    private struct AnswerCommand<Value: Encodable>: Encodable {
        var t = "answer"
        var id: String
        var promptId: String
        var value: Value
    }

    static func answerCommand(id: String, promptID: String, _ answer: PiPromptAnswer) throws -> Data {
        switch answer {
        case .option(let value), .text(let value): try encodeLine(AnswerCommand(id: id, promptId: promptID, value: value))
        case .confirmed(let value): try encodeLine(AnswerCommand(id: id, promptId: promptID, value: value))
        }
    }

    private static func encodeLine(_ command: some Encodable) throws -> Data {
        try JSONEncoder().encode(command) + Data([0x0A])
    }

    private static func encode(_ command: Command) throws -> Data { try encodeLine(command) }
}
#endif
