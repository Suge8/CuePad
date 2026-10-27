#if os(macOS)
import CueStore
import Foundation

/// Agent 发来、要你回答的一问：标准的权限确认（`permission`），或各家自己的提问请求（`ACPDialect.ask`）翻成的。
/// 驱动只认这一种：托管会话把它放进 CuePad 的提问（`promptID` 由驱动给），作答经 `answer` 翻回去；没答就作废（这一轮停下、结束，
/// 或又来一问）时回 `withdrawn`。一个请求里有几问的（分批提问，`inOrder`）逐问来：`answer` 回下一问，最后一问答完才回给 Agent。
struct ACPAsk {
    var question: PiQuestion
    /// 你的答案：回给 Agent 的结果、接着问的下一问；答案不合这一问为 nil（`bad_answer`）
    var answer: (PiAnswerValue) -> ACPReply?
    var withdrawn: JSONValue
}

enum ACPReply {
    case result(JSONValue)
    case next(ACPAsk)
}

extension ACPAsk {
    /// 一个请求里的几问逐问来：`ask` 给一问的样子与怎么收它的答案（不合这一问为 nil），答完全部问题后 `finish` 出回给 Agent 的结果。
    /// 各家提问请求里的选项（`options[{label, description}]`）与说明行也经这里读（`labels`、`notes`）。
    static func inOrder<Answer>(
        _ questions: [JSONValue], ask: @escaping (JSONValue) -> (question: PiQuestion, accept: (PiAnswerValue) -> Answer?),
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

    /// 有说明的选项各一行（`标签：说明`）
    static func notes(_ question: JSONValue) -> [String] {
        (question["options"]?.array ?? []).compactMap { option in
            option["description"]?.string.flatMap { $0.isEmpty ? nil : "\(option["label"]?.string ?? "")：\($0)" }
        }
    }

    /// 问题的文字：几行拼起来，至多 500 字
    static func text(_ lines: [String]) -> String { String(lines.joined(separator: "\n").prefix(500)) }

    /// 权限确认（`session/request_permission`）：允许回 allow_once（没有就 allow_always），拒绝回 reject_once（没有就 reject_always），
    /// 作废回 `cancelled`（协议要求）。
    static func permission(_ params: JSONValue, agent: AgentKind, dialect: any ACPDialect) -> ACPAsk {
        let options = params["options"]?.array ?? []
        let call = params["toolCall"] ?? [:]
        let name = ToolDetail.name(dialect.tool(call).name)
        let text = PermissionWording.question(agent, String(localized: "使用 \(name)"), [ToolDetail.target(call["rawInput"]), call["title"]?.string])
        return ACPAsk(question: PiQuestion(promptID: nil, kind: .confirm, text: text), answer: { answer in
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
