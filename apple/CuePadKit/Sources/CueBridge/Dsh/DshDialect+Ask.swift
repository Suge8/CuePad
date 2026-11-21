#if os(macOS)
import CueStore
import Foundation

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
                ? Question(promptID: nil, kind: .text, text: ACPAsk.text(lines))
                : Question(promptID: nil, kind: .select, text: ACPAsk.text(lines), options: labels, allowsOther: true)
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
