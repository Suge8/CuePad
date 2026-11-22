#if os(macOS)
import CueStore
import Foundation

enum PiWire {
    static let oldestExtension = 70

    static func reads(extensionVersion version: Int) -> Bool { (oldestExtension...PiExtensionBundle.version).contains(version) }

    struct State: Decodable {
        var kind: String
        var tool: String?
        var detail: String?
        var title: String?
        var error: String?
        var since: Double
        var busySince: Double?
        var turnSince: Double?
        var opener: Opener?

        struct Opener: Decodable {
            var delivery: String
            var cue: Bool
        }

        var work: (state: WorkState, detail: String?)? {
            switch kind {
            case "idle": (.settled, nil)
            case "thinking": (.thinking, nil)
            case "tool": (.tool, detail.map { "\(tool ?? "?")\(SessionState.detailSeparator)\($0)" } ?? tool ?? "?")
            case "delegating": (.delegating, nil)
            case "compacting": (.compacting, nil)
            case "waiting_user": (.waitingForUser, title)
            case "error": (.error, ErrorSummary(error ?? "").line)
            default: nil
            }
        }

        var errorMessage: String? { kind == "error" ? error ?? "" : nil }

        var sinceDate: Date { Date(timeIntervalSince1970: since / 1000) }
        var busySinceDate: Date? { busySince.map { Date(timeIntervalSince1970: $0 / 1000) } }
        var turnSinceDate: Date? { turnSince.map { Date(timeIntervalSince1970: $0 / 1000) } }
        var turnOpener: TurnOpener? { opener.flatMap { o in UUID(uuidString: o.delivery).map { TurnOpener(delivery: $0, cue: o.cue) } } }
    }

    struct Hello: Decodable {
        var extensionVersion: Int
        var sessionId: String
        var sessionFile: String?
        var pid: Int32
        var cwd: String
        var state: State
        var launchToken: String?
        var info: Info

        enum CodingKeys: String, CodingKey {
            case extensionVersion, sessionId, sessionFile, pid, cwd, state, launchToken
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            extensionVersion = try c.decode(Int.self, forKey: .extensionVersion)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            sessionFile = try c.decodeIfPresent(String.self, forKey: .sessionFile)
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decode(String.self, forKey: .cwd)
            state = try c.decode(State.self, forKey: .state)
            launchToken = try c.decodeIfPresent(String.self, forKey: .launchToken)
            info = try Info(from: decoder)
        }
    }

    struct IdentityHello: Decodable {
        var extensionVersion: Int
        var sessionId: String
        var sessionFile: String?
        var pid: Int32
        var cwd: String
        var name: String?
        var firstMessage: String?

        enum CodingKeys: String, CodingKey {
            case extensionVersion, sessionId, sessionFile, pid, cwd, name, firstMessage
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            extensionVersion = try c.decode(Int.self, forKey: .extensionVersion)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            sessionFile = try? c.decode(String.self, forKey: .sessionFile)
            pid = try c.decode(Int32.self, forKey: .pid)
            cwd = try c.decode(String.self, forKey: .cwd)
            name = try? c.decode(String.self, forKey: .name)
            firstMessage = try? c.decode(String.self, forKey: .firstMessage)
        }
    }

    struct Info: Decodable {
        private var updates: [@Sendable (inout Session) -> Void] = []

        private enum CodingKeys: String, CodingKey {
            case name, firstMessage, question, subagents, model, thinking, fast, models, proofs, context, commands
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field<Value: Decodable & Sendable>(
                _ key: CodingKeys, _ type: Value.Type, _ set: @escaping @Sendable (inout Session, Value?) -> Void
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
            try field(.model, ModelOption.self) { $0.model = $1 }
            try field(.thinking, Open<ThinkingLevel>.self) { $0.thinking = $1 }
            try field(.fast, Bool.self) { $0.fast = $1 }
            try field(.models, [ModelOption].self) { $0.availableModels = $1 ?? [] }
            try field(.proofs, [PiProof].self) { $0.proofs = $1 ?? [] }
            try field(.context, ContextUsage.self) { $0.context = $1 }
            try field(.commands, [WireCommand].self) { $0.commands = $1?.map(\.command) ?? [] }
        }

        func apply(to session: inout Session) {
            for update in updates { update(&session) }
        }

        private static func stamped(_ roster: [SubagentState], since previous: [SubagentState], at now: Date) -> [SubagentState] {
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

        var question: Question { Question(promptID: id, kind: Open(rawValue: kind), text: text, options: options ?? []) }
    }

    private struct WireSubagent: Decodable {
        var name: String
        var role: String
        var state: String
        var action: String
        var startedAt: Double?
        var settledAt: Double?
        var model: String?

        var subagent: SubagentState {
            func date(_ milliseconds: Double?) -> Date? { milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } }
            return SubagentState(
                name: name, role: role, phase: Open(rawValue: state), action: action, startedAt: date(startedAt), settledAt: date(settledAt),
                model: model)
        }
    }

    private struct WireCommand: Decodable {
        var name: String
        var description: String?
        var source: String
        var hint: String?

        var command: SlashCommand { SlashCommand(name: name, summary: description, source: Open(rawValue: source), hint: hint) }
    }

    struct Ack: Decodable {
        var id: String?
        var ok: Bool
        var error: String?
        var title: String?
    }

    struct Bye: Decodable { var reason: String }

    static let upgrade = Data(#"{"t":"upgrade"}"#.utf8) + Data([0x0A])

    static func identityBye(_ line: Data) -> Bye? {
        struct Tagged: Decodable { var t: String; var reason: String }
        guard let tagged = try? JSONDecoder().decode(Tagged.self, from: line), tagged.t == "bye" else { return nil }
        return Bye(reason: tagged.reason)
    }
    struct StateMessage: Decodable { var state: State }

    struct Draft: Decodable {
        var text: String?
        var since: Double?

        var draft: LiveDraft? {
            guard let text, let since else { return nil }
            return LiveDraft(text: text, since: Date(timeIntervalSince1970: since / 1000))
        }
    }

    enum Message {
        case hello(Hello)
        case upgrading(IdentityHello)
        case state(State)
        case info(Info)
        case ack(Ack)
        case bye(Bye)
        case draft(LiveDraft?)
        case quota(QuotaReport)
    }

    enum DecodeError: Error { case unknownType(String) }

    static func decode(_ line: Data) throws -> Message {
        struct Envelope: Decodable { var t: String }
        let decoder = JSONDecoder()
        switch try decoder.decode(Envelope.self, from: line).t {
        case "hello":
            let identity = try decoder.decode(IdentityHello.self, from: line)
            return reads(extensionVersion: identity.extensionVersion) ? .hello(try decoder.decode(Hello.self, from: line)) : .upgrading(identity)
        case "state": return .state(try decoder.decode(StateMessage.self, from: line).state)
        case "info": return .info(try decoder.decode(Info.self, from: line))
        case "ack": return .ack(try decoder.decode(Ack.self, from: line))
        case "bye": return .bye(try decoder.decode(Bye.self, from: line))
        case "draft": return .draft(try decoder.decode(Draft.self, from: line).draft)
        case "quota":
            let seconds = JSONDecoder()
            seconds.dateDecodingStrategy = .secondsSince1970
            return .quota(try seconds.decode(QuotaReport.self, from: line))
        case let other: throw DecodeError.unknownType(other)
        }
    }

    private struct Command: Encodable {
        struct Image: Encodable { var mimeType: String; var data: String }
        var t: String
        var id: String
        var text: String
        var images: [Image]?
        var deliveryId: String?
        var cue: Bool?
    }

    static func sendCommand(id: String, _ message: SessionMessage) throws -> Data {
        try encodeLine(Command(
            t: "send", id: id, text: message.text,
            images: message.images.isEmpty ? nil : message.images.map { .init(mimeType: $0.mimeType, data: $0.data.base64EncodedString()) },
            deliveryId: message.deliveryID, cue: message.policy == .cue ? true : nil))
    }

    static func slashCommand(id: String, line: String) throws -> Data {
        try encodeLine(Command(t: "command", id: id, text: line))
    }

    private struct Bare: Encodable {
        var t: String
        var id: String
    }

    static func bare(_ t: String, id: String) throws -> Data { try encodeLine(Bare(t: t, id: id)) }

    private struct ConfigCommand: Encodable {
        var t = "config"
        var id: String
        var model: ModelKey?
        var thinking: String?
        var fast: Bool?
        var name: String?
    }

    static func configCommand(id: String, model: ModelKey?, thinking: ThinkingLevel?, fast: Bool? = nil, name: String?) throws -> Data {
        try encodeLine(ConfigCommand(id: id, model: model, thinking: thinking?.rawValue, fast: fast, name: name))
    }

    private struct TitleCommand: Encodable {
        var t = "title"
        var id: String
        var instructions = SessionNameSuggestion.instructions
        var text: String
        var timeoutMs = Int(SessionNameSuggestion.budget.seconds * 1000)
    }

    static func titleCommand(id: String, text: String) throws -> Data { try encodeLine(TitleCommand(id: id, text: text)) }

    private struct AnswerCommand<Value: Encodable>: Encodable {
        var t = "answer"
        var id: String
        var promptId: String
        var value: Value
    }

    static func answerCommand(id: String, promptID: String, _ answer: AnswerValue) throws -> Data {
        switch answer {
        case .option(let value), .text(let value): try encodeLine(AnswerCommand(id: id, promptId: promptID, value: value))
        case .confirmed(let value): try encodeLine(AnswerCommand(id: id, promptId: promptID, value: value))
        }
    }

    private static func encodeLine(_ command: some Encodable) throws -> Data {
        try JSONEncoder().encode(command) + Data([0x0A])
    }
}
#endif
