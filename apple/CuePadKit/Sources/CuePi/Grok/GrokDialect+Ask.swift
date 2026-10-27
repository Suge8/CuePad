#if os(macOS)
import CueStore
import Foundation

/// Grok 的提问（`ask_user_question` 工具发来的 `_x.ai/ask_user_question`：`questions[{question, options[{label, description}], multiSelect}]`）。
/// 几问逐问来（`ACPReply.next`），都答完回 `{"outcome": "accepted", "answers": {问题原文: 答案}}`；作废回 `{"outcome": "cancelled"}`
/// （Grok 告诉模型你没答、让它自己拿主意）。回法实测 1.0.52：结果没有 `outcome` 时它报"Client returned an invalid response"。
/// 单选照它的选项，也能自己填（它的问题卡总有自由作答的一行）；多选写成文字题，选项列在问题后面，答的字原样交回。
extension GrokDialect {
    func ask(_ method: String, _ params: JSONValue) -> ACPAsk? {
        guard method == "_x.ai/ask_user_question" else { return nil }
        let questions = (params["questions"]?.array ?? []).filter { $0["question"]?.string?.isEmpty == false }
        return questions.isEmpty ? nil : Self.ask(questions[...], answers: [:])
    }

    private static func ask(_ questions: ArraySlice<JSONValue>, answers: [String: String]) -> ACPAsk {
        let current = questions[questions.startIndex]
        let title = current["question"]?.string ?? ""
        let options = current["options"]?.array ?? []
        let labels = options.compactMap { $0["label"]?.string }
        let notes = options.compactMap { option in
            option["description"]?.string.flatMap { $0.isEmpty ? nil : "\(option["label"]?.string ?? "")：\($0)" }
        }
        let question = if current["multiSelect"]?.bool == true || labels.isEmpty {
            PiQuestion(promptID: nil, kind: .text, text: Self.clip(([labels.isEmpty ? title : "\(title)（\(labels.joined(separator: " / "))）"] + notes)))
        } else {
            PiQuestion(promptID: nil, kind: .select, text: Self.clip([title] + notes), options: labels, allowsOther: true)
        }
        return ACPAsk(question: question, answer: { answer in
            let said: String
            switch answer {
            case .option(let option) where question.options.contains(option): said = option
            case .text(let text) where question.acceptsText: said = text
            default: return nil
            }
            var answers = answers
            answers[title] = said
            let rest = questions.dropFirst()
            guard rest.isEmpty else { return .next(ask(rest, answers: answers)) }
            return .result(["outcome": "accepted", "answers": .object(answers.mapValues(JSONValue.string))])
        }, withdrawn: ["outcome": "cancelled"])
    }

    private static func clip(_ lines: [String]) -> String { String(lines.joined(separator: "\n").prefix(500)) }
}
#endif
