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
        guard !questions.isEmpty else { return nil }
        return .inOrder(questions, ask: { current in
            let id = current["id"] ?? .null
            let labels = ACPAsk.labels(current)
            let lines = [current["header"]?.string, current["question"]?.string, current["detail"]?.string].compactMap(\.self) + ACPAsk.notes(current)
            let question = labels.isEmpty
                ? PiQuestion(promptID: nil, kind: .text, text: ACPAsk.text(lines))
                : PiQuestion(promptID: nil, kind: .select, text: ACPAsk.text(lines), options: labels, allowsOther: true)
            return (question, { answer in
                switch answer {
                case .option(let label) where labels.contains(label): ["id": id, "selected": [.string(label)]]
                case .text(let written) where question.acceptsText && !written.isEmpty: ["id": id, "selected": [], "custom": .string(written)]
                default: nil
                }
            })
        }, finish: { ["answers": .array($0)] }, withdrawn: ["cancelled": true])
    }
}
#endif
