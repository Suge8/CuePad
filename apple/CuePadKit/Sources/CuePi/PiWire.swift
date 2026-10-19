#if os(macOS)
import CueStore
import Foundation

/// 桥协议的线上格式：一行一个 JSON。扩展端见 `Extension/cuepad-bridge.ts`。
enum PiWire {
    /// 客户端说的协议版本；hello 的版本不同就不往下解析（命令一条不发），会话只当"需要 /reload"（`OtherProtocolHello`）
    static let protocolVersion = 15

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
        /// 主会话最后一次模型回合开始的时间（毫秒）；还没开过为 nil
        var turnSince: Double?

        /// 同步记录的状态与一句话说明（`PiSession.detail`）；不认识的种类为 nil。扩展还报的在跑工具全集、`aborted`、弹窗种类没有人读，不解码。
        var work: (state: PiWorkState, detail: String?)? {
            switch kind {
            case "idle", "done": (.settled, nil)
            case "thinking": (.thinking, nil)
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
        var turnSinceDate: Date? { turnSince.map { Date(timeIntervalSince1970: $0 / 1000) } }
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
    /// `hosted` 也读：托管的旧版进程没有终端能 /reload，CuePad 要认出它、让它退出（`PiBridge`）。
    /// `sessionFile` 也读：/reload 时旧连接告别，说没说过话（`PiSession.spoke`）看它，读不到就会把说过话的会话当成没说话、删掉记录与摘要。
    struct OtherProtocolHello: Decodable {
        var protocolVersion: Int
        var extensionVersion: Int
        var sessionId: String
        var sessionFile: String?
        var pid: Int32
        var cwd: String
        var name: String?
        var firstMessage: String?
        var hosted: Bool

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case extensionVersion, sessionId, sessionFile, pid, cwd, name, firstMessage, hosted
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
            extensionVersion = (try? c.decode(Int.self, forKey: .extensionVersion)) ?? 0
            sessionId = try c.decode(String.self, forKey: .sessionId)
            sessionFile = try? c.decode(String.self, forKey: .sessionFile)
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decode(String.self, forKey: .cwd)
            name = try? c.decode(String.self, forKey: .name)
            firstMessage = try? c.decode(String.self, forKey: .firstMessage)
            hosted = (try? c.decode(Bool.self, forKey: .hosted)) ?? false
        }
    }

    /// 会话名、首条用户消息、等你回答的弹窗、子代理、模型配置、上下文余量与命令清单。hello 带全部；`info` 消息只带变了的几项：
    /// 键出现就是新值（null 是"没有"），没出现就是不变（模型表和命令清单很大，上下文用量每轮都变，不整份重发）。
    /// 模型与上下文的线上格式就是同步字段的格式（直接解码成 CueStore 的类型）；弹窗、子代理、命令的键名或时刻单位不同，经下面三个线上形状转成。
    /// 问答近况不走这里：对话与摘要只来自会话文件（`PiHistory`）。
    struct Info: Decodable {
        private var updates: [@Sendable (inout PiSession) -> Void] = []

        private enum CodingKeys: String, CodingKey {
            case name, firstMessage, question, subagents, model, thinking, models, context, commands
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field<Value: Decodable & Sendable>(
                _ key: CodingKeys, _ type: Value.Type, _ set: @escaping @Sendable (inout PiSession, Value?) -> Void
            ) throws {
                guard c.contains(key) else { return }
                let value = try c.decodeIfPresent(type, forKey: key)
                updates.append { set(&$0, value) }
            }
            try field(.name, String.self) { $0.name = $1 }
            try field(.firstMessage, String.self) { $0.firstMessage = $1 }
            try field(.question, WireQuestion.self) { $0.question = $1?.question }
            try field(.subagents, [WireSubagent].self) { session, roster in
                session.subagents = Self.stamped(roster?.map(\.subagent) ?? [], since: session.subagents, at: Date())
            }
            try field(.model, PiModelOption.self) { $0.model = $1 }
            try field(.thinking, Open<PiThinkingLevel>.self) { $0.thinking = $1 }
            try field(.models, [PiModelOption].self) { $0.availableModels = $1 ?? [] }
            try field(.context, PiContextUsage.self) { $0.context = $1 }
            try field(.commands, [WireCommand].self) { $0.commands = $1?.map(\.command) ?? [] }
        }

        func apply(to session: inout PiSession) {
            for update in updates { update(&session) }
        }

        /// 名册不带进展时刻，Mac 收到时记（`PiSubagentState.progressAt`）：一项（按名字对上上一份）有任何变化——状态、动作文字、起止——就是此刻有进展，
        /// 没变的沿用上一份的时刻，新出现的是此刻。FireCode 的名字在一个指挥官下唯一。
        private static func stamped(_ roster: [PiSubagentState], since previous: [PiSubagentState], at now: Date) -> [PiSubagentState] {
            roster.map { agent in
                var agent = agent
                let before = previous.first { $0.name == agent.name }
                var unstamped = before
                unstamped?.progressAt = nil
                agent.progressAt = unstamped == agent ? before?.progressAt : now
                return agent
            }
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
        var model: String?

        var subagent: PiSubagentState {
            func date(_ milliseconds: Double?) -> Date? { milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } }
            return PiSubagentState(
                name: name, role: role, phase: Open(rawValue: state), action: action, startedAt: date(startedAt), settledAt: date(settledAt),
                model: model)
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

    /// 正在说的话：到目前为止的全文与开始出字的时刻（毫秒）；`text` 为 null 是清掉。
    struct Draft: Decodable {
        var text: String?
        var since: Double?

        var draft: PiDraft? {
            guard let text, let since else { return nil }
            return PiDraft(text: text, since: Date(timeIntervalSince1970: since / 1000))
        }
    }

    enum Message {
        case hello(Hello)
        case otherProtocol(OtherProtocolHello)
        case state(State)
        case info(Info)
        case ack(Ack)
        case bye(Bye)
        /// 正在说的话（`PiDraft`），nil 是清掉
        case draft(PiDraft?)
        /// 订阅额度的一次观测（属于账号，不属于会话）
        case quota(QuotaReport)
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
        case "draft": return .draft(try decoder.decode(Draft.self, from: line).draft)
        case "quota":
            let seconds = JSONDecoder()
            seconds.dateDecodingStrategy = .secondsSince1970  // 重置时刻是 Unix 秒
            return .quota(try seconds.decode(QuotaReport.self, from: line))
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

    private struct QuotaCommand: Encodable {
        var t = "quota"
        var id: String
    }

    static func quotaCommand(id: String) throws -> Data { try encodeLine(QuotaCommand(id: id)) }

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
