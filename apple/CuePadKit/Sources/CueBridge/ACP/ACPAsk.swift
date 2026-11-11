#if os(macOS)
import CueStore
import Foundation

/// 驱动只认这一种：没答就作废（这一轮停下、结束，或又来一问）时回 `withdrawn`。一个请求里有几问的（分批提问，`inOrder`）逐问来：`answer` 回下一问，最后一问答完才回给 Agent。
struct ACPAsk {
    var question: Question
    /// 答案不合这一问为 nil（`bad_answer`）。
    var answer: (AnswerValue) -> ACPReply?
    var withdrawn: JSONValue
}

enum ACPReply {
    case result(JSONValue)
    case next(ACPAsk)
}

extension ACPAsk {
    /// 一个请求里的几问逐问来：`ask` 给一问的样子与怎么收它的答案（不合这一问为 nil），答完全部问题后 `finish` 出回给 Agent 的结果。
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

    /// 大脑没人可问：权限一律允许（它只有读文件与 CuePad 的工具）
    static func allowed(_ params: JSONValue) -> JSONValue {
        selected(params["options"]?.array ?? [], ["allow_once", "allow_always"]) ?? ["outcome": ["outcome": "cancelled"]]
    }

    private static func selected(_ options: [JSONValue], _ kinds: [String]) -> JSONValue? {
        kinds.lazy.compactMap { kind in options.first { $0["kind"]?.string == kind }?["optionId"] }.first
            .map { ["outcome": ["outcome": "selected", "optionId": $0]] }
    }
}
#endif
