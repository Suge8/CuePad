#if os(macOS)
import CueStore
import Foundation

struct ACPAsk {
    var question: Question
    var answer: (AnswerValue) -> ACPReply?
    var withdrawn: JSONValue
}

enum ACPReply {
    case result(JSONValue)
    case next(ACPAsk)
}

extension ACPAsk {
    static func inOrder<Answer>(
        _ questions: [JSONValue], ask: @escaping (JSONValue) -> (question: Question, accept: (AnswerValue) -> Answer?),
        finish: @escaping ([Answer]) -> JSONValue, withdrawn: JSONValue
    ) -> ACPAsk {
        func step(_ rest: ArraySlice<JSONValue>, _ answered: [Answer]) -> ACPAsk {
            let (question, accept) = ask(rest[rest.startIndex])
            return ACPAsk(question: question, answer: { answer in
                guard let accepted = accept(answer) else { return nil }
                let next = rest.dropFirst()
                return next.isEmpty ? .result(finish(answered + [accepted])) : .next(step(next, answered + [accepted]))
            }, withdrawn: withdrawn)
        }
        return step(questions[...], [])
    }

    static func labels(_ question: JSONValue) -> [String] { (question["options"]?.array ?? []).compactMap { $0["label"]?.string } }

    static func notes(_ question: JSONValue) -> [String] {
        (question["options"]?.array ?? []).compactMap { option in
            option["description"]?.string.flatMap { $0.isEmpty ? nil : "\(option["label"]?.string ?? "")：\($0)" }
        }
    }

    static func text(_ lines: [String]) -> String { String(lines.joined(separator: "\n").prefix(500)) }

    /// 作废回 `cancelled`（协议要求）。
    static func permission(_ params: JSONValue, agent: AgentKind, dialect: any ACPDialect) -> ACPAsk {
        let options = params["options"]?.array ?? []
        let call = params["toolCall"] ?? [:]
        let name = ToolDetail.name(dialect.tool(call).name)
        let text = PermissionWording.question(agent, String(localized: "使用 \(name)"), [ToolDetail.target(call["rawInput"]), call["title"]?.string])
        return ACPAsk(question: Question(promptID: nil, kind: .confirm, text: text), answer: { answer in
            guard case .confirmed(let allowed) = answer else { return nil }
            return selected(options, allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]).map(ACPReply.result)
        }, withdrawn: ["outcome": ["outcome": "cancelled"]])
    }

    static func allowed(_ params: JSONValue) -> JSONValue {
        selected(params["options"]?.array ?? [], ["allow_once", "allow_always"]) ?? ["outcome": ["outcome": "cancelled"]]
    }

    private static func selected(_ options: [JSONValue], _ kinds: [String]) -> JSONValue? {
        kinds.lazy.compactMap { kind in options.first { $0["kind"]?.string == kind }?["optionId"] }.first
            .map { ["outcome": ["outcome": "selected", "optionId": $0]] }
    }
}
#endif
