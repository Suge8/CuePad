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
        guard !questions.isEmpty else { return nil }
        return .inOrder(questions, ask: { current in
            let title = current["question"]?.string ?? ""
            let labels = ACPAsk.labels(current), notes = ACPAsk.notes(current)
            let question = if current["multiSelect"]?.bool == true || labels.isEmpty {
                PiQuestion(promptID: nil, kind: .text, text: ACPAsk.text([labels.isEmpty ? title : "\(title)（\(labels.joined(separator: " / "))）"] + notes))
            } else {
                PiQuestion(promptID: nil, kind: .select, text: ACPAsk.text([title] + notes), options: labels, allowsOther: true)
            }
            return (question, { answer in
                switch answer {
                case .option(let option) where question.options.contains(option): (title, option)
                case .text(let text) where question.acceptsText: (title, text)
                default: nil
                }
            })
        }, finish: { answers in
            ["outcome": "accepted", "answers": .object(Dictionary(answers, uniquingKeysWith: { $1 }).mapValues(JSONValue.string))]
        }, withdrawn: ["outcome": "cancelled"])
    }
}
#endif
