#if os(macOS)
import CueStore
import Foundation

/// 桥协议的线上格式：一行一个 JSON。扩展端见 `Extension/cuepad-bridge.ts`。
enum PiWire {
    /// 客户端说的协议版本；hello 的版本不同就不往下解析（命令一条不发），会话只当"需要 /reload"（`OtherProtocolHello`）
    static let protocolVersion = 10

    struct State: Decodable {
        var kind: String
        var tool: String?
        var detail: String?
        var title: String?
        var error: String?
        /// 进入当前粗状态的时间（毫秒）
        var since: Double
        /// 这段连续处理开始的时间（毫秒），空闲、出错时为 nil
        var busySince: Double?

        /// 同步记录的状态与一句话说明（`PiSession.detail`）；不认识的种类为 nil。扩展还报的在跑工具全集、`aborted`、弹窗种类没有人读，不解码。
        var work: (state: PiWorkState, detail: String?)? {
            switch kind {
            case "idle", "done": (.settled, nil)
            case "thinking": (.thinking, nil)
            case "outputting": (.outputting, nil)
            case "tool": (.tool, detail.map { "\(tool ?? "?")\(PiSessionState.detailSeparator)\($0)" } ?? tool ?? "?")
            case "delegating": (.delegating, nil)  // 子代理在 `subagents` 里
            case "compacting": (.compacting, nil)
            case "waiting_user": (.waitingForUser, title)
            case "error": (.error, PiErrorSummary(error ?? "").line)  // 手机上没有悬停看原文
            default: nil
            }
        }

        var errorMessage: String? { kind == "error" ? error ?? "" : nil }

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
        var tty: String?
        var term: [String: String]
        var state: State
        /// CuePad 开的新会话：启动时经环境变量交给扩展的认领标识（其余会话没有）
        var launchToken: String?
        /// CuePad 在后台托管的 Pi
        var hosted: Bool?
        /// 与 `info` 消息同样的字段，平铺在 hello 里
        var info: Info

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case extensionVersion, sessionId, sessionFile, pid, cwd, tty, term, state, launchToken, hosted
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
            extensionVersion = try c.decode(Int.self, forKey: .extensionVersion)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            sessionFile = try c.decodeIfPresent(String.self, forKey: .sessionFile)
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decode(String.self, forKey: .cwd)
            tty = try c.decodeIfPresent(String.self, forKey: .tty)
            term = try c.decode([String: String].self, forKey: .term)
            state = try c.decode(State.self, forKey: .state)
            launchToken = try c.decodeIfPresent(String.self, forKey: .launchToken)
            hosted = try c.decodeIfPresent(Bool.self, forKey: .hosted)
            info = try Info(from: decoder)
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

    /// 会话名、首条用户消息、等你回答的弹窗、子代理、模型配置、上下文余量与命令清单；没有的为 nil。
    /// 模型与上下文的线上格式就是同步字段的格式（直接解码成 CueStore 的类型）；弹窗、子代理、命令的键名或时刻单位不同，经下面三个线上形状转成。
    /// 问答近况不走这里：对话与摘要只来自会话文件（`PiHistory`）。
    struct Info: Decodable {
        var name: String?
        var firstMessage: String?
        var question: PiQuestion?
        var subagents: [PiSubagentState]?
        var model: PiModelOption?
        var thinking: Open<PiThinkingLevel>?
        var models: [PiModelOption]?
        var context: PiContextUsage?
        var commands: [PiSlashCommand]?

        private enum CodingKeys: String, CodingKey {
            case name, firstMessage, question, subagents, model, thinking, models, context, commands
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage)
            question = try c.decodeIfPresent(WireQuestion.self, forKey: .question)?.question
            subagents = try c.decodeIfPresent([WireSubagent].self, forKey: .subagents)?.map(\.subagent)
            model = try c.decodeIfPresent(PiModelOption.self, forKey: .model)
            thinking = try c.decodeIfPresent(Open<PiThinkingLevel>.self, forKey: .thinking)
            models = try c.decodeIfPresent([PiModelOption].self, forKey: .models)
            context = try c.decodeIfPresent(PiContextUsage.self, forKey: .context)
            commands = try c.decodeIfPresent([WireCommand].self, forKey: .commands)?.map(\.command)
        }

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

    private struct WireQuestion: Decodable {
        var id: String?
        var kind: String
        var text: String
        var options: [String]?

        var question: PiQuestion { PiQuestion(promptID: id, kind: Open(rawValue: kind), text: text, options: options ?? []) }
    }

    private struct WireSubagent: Decodable {
        var name: String
        var role: String
        var state: String
        var action: String
        /// 毫秒
        var startedAt: Double?
        var settledAt: Double?

        var subagent: PiSubagentState {
            func date(_ milliseconds: Double?) -> Date? { milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } }
            return PiSubagentState(
                name: name, role: role, phase: Open(rawValue: state), action: action, startedAt: date(startedAt), settledAt: date(settledAt))
        }
    }

    private struct WireCommand: Decodable {
        var name: String
        var description: String?
        var source: String
        var hint: String?

        var command: PiSlashCommand { PiSlashCommand(name: name, summary: description, source: Open(rawValue: source), hint: hint) }
    }

    struct Ack: Decodable {
        var id: String?
        var ok: Bool
        var delivered: String?
        var error: String?
    }

    struct Bye: Decodable { var reason: String; var undelivered: [String]? }
    struct StateMessage: Decodable { var state: State }

    enum Message {
        case hello(Hello)
        case otherProtocol(OtherProtocolHello)
        case state(State)
        case info(Info)
        case ack(Ack)
        case bye(Bye)
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
        case "bye": return .bye(try decoder.decode(Bye.self, from: line))
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
        var t = "config"
        var id: String
        var model: PiModelKey?
        var thinking: String?
        var name: String?
    }

    static func configCommand(id: String, model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) throws -> Data {
        try encodeLine(ConfigCommand(id: id, model: model, thinking: thinking?.rawValue, name: name))
    }

    private struct AnswerCommand<Value: Encodable>: Encodable {
        var t = "answer"
        var id: String
        var promptId: String
        var value: Value
    }

    static func answerCommand(id: String, promptID: String, _ answer: PiAnswerValue) throws -> Data {
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
