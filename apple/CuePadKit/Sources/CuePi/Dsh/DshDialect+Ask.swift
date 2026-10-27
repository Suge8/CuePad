#if os(macOS)
import CueStore
import Foundation

/// dsh 的提问（`ask_user_question` 工具，插件转成请求 `_cuepad/ask_user_question` {sessionId, questions[{id, question, header?, detail?,
/// options?[{label, description?}], multiSelect?}]}）。几问逐问来（`ACPReply.next`），都答完回 `{answers[{id, selected[], custom?}]}`
/// （dsh 的 `AskUserQuestionAnswer`）；作废回 `{cancelled: true}`，插件让这次提问失败。
/// dsh 的会话只有 CuePad 托管的，没有别处能答：没有选项的是文字题，有选项的每问都能自己填（`custom`），多选的也只选一项。
extension DshDialect {
    func ask(_ method: String, _ params: JSONValue) -> ACPAsk? {
        guard method == "_cuepad/ask_user_question" else { return nil }
        let questions = (params["questions"]?.array ?? []).filter { $0["id"]?.string != nil && $0["question"]?.string?.isEmpty == false }
        return questions.isEmpty ? nil : Self.ask(questions[...], answers: [])
    }

    private static func ask(_ questions: ArraySlice<JSONValue>, answers: [JSONValue]) -> ACPAsk {
        let current = questions[questions.startIndex]
        let id = current["id"] ?? .null
        let options = current["options"]?.array ?? []
        let labels = options.compactMap { $0["label"]?.string }
        let notes = options.compactMap { option in
            option["description"]?.string.flatMap { $0.isEmpty ? nil : "\(option["label"]?.string ?? "")：\($0)" }
        }
        let text = String(([current["header"]?.string, current["question"]?.string, current["detail"]?.string].compactMap(\.self) + notes)
            .joined(separator: "\n").prefix(textLimit))
        let question = labels.isEmpty
            ? PiQuestion(promptID: nil, kind: .text, text: text)
            : PiQuestion(promptID: nil, kind: .select, text: text, options: labels, allowsOther: true)
        return ACPAsk(question: question, answer: { answer in
            let item: JSONValue
            switch answer {
            case .option(let label) where labels.contains(label): item = ["id": id, "selected": [.string(label)]]
            case .text(let written) where question.acceptsText && !written.isEmpty: item = ["id": id, "selected": [], "custom": .string(written)]
            default: return nil
            }
            let rest = questions.dropFirst()
            guard rest.isEmpty else { return .next(ask(rest, answers: answers + [item])) }
            return .result(["answers": .array(answers + [item])])
        }, withdrawn: ["cancelled": true])
    }

    private static let textLimit = 500
}
#endif
