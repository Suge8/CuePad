#if os(macOS)
import CueStore
import CueText
import Foundation

/// dsh 的 `ask_user_question`（插件的 `_cuepad/question`）：一次可问好几道，CuePad 一道一道问——答完一道显示下一道，最后一道答完
/// 把全部答案一次交回（`_cuepad/answer` 的参数）。没有选项的是文字题；有选项的每道都能自己填（dsh 的答案带 `custom`），
/// 多选题也只选一项（`selected` 是一项的数组）。dsh 的会话没有别处能答，所以每道都能从 CuePad 答。
struct DshQuestions {
    /// 插件给这次提问的 id（`_cuepad/answer` 的 `id`）
    let id: String
    private let items: [Item]
    private var answers: [JSONValue] = []

    private struct Item {
        let id: String
        let text: String
        let options: [String]
    }

    private static let textLimit = 500

    /// `_cuepad/question` 的参数；`questions` 为 null（收回）或一道都读不出时为 nil。
    init?(_ params: JSONValue) {
        guard let id = params["id"]?.string, let questions = params["questions"]?.array else { return nil }
        let items = questions.compactMap { question -> Item? in
            guard let qid = question["id"]?.string, let text = question["question"]?.string else { return nil }
            let lines = [question["header"]?.string, text, question["detail"]?.string].compactMap { $0 }
            return Item(id: qid, text: lines.joined(separator: "\n").clipped(Self.textLimit), options: question["options"]?.array?.compactMap { $0["label"]?.string } ?? [])
        }
        guard !items.isEmpty else { return nil }
        self.id = id
        self.items = items
    }

    /// 这会儿要你答的那道（作答标识是 `<提问 id>#<第几道>`）。
    var current: PiQuestion {
        let item = items[answers.count]
        let promptID = "\(id)#\(answers.count)"
        if item.options.isEmpty { return PiQuestion(promptID: promptID, kind: .text, text: item.text) }
        return PiQuestion(promptID: promptID, kind: .select, text: item.text, options: item.options, allowsOther: true)
    }

    /// 答这一道：还有下一道返回 nil（`current` 换成它），答完最后一道返回 `_cuepad/answer` 的参数。
    /// 标识对不上（答的是已经过去的一道）抛 `stale_prompt`，答案对不上抛 `bad_answer`。
    mutating func answer(_ value: PiAnswerValue, to promptID: String) throws -> JSONValue? {
        guard promptID == current.promptID else { throw PiBridgeError.rejected("stale_prompt") }
        let item = items[answers.count]
        switch value {
        case .option(let label) where item.options.contains(label):
            answers.append(["id": .string(item.id), "selected": [.string(label)]])
        case .text(let text) where !text.isEmpty:
            answers.append(["id": .string(item.id), "selected": [], "custom": .string(text)])
        default:
            throw PiBridgeError.rejected("bad_answer")
        }
        guard answers.count == items.count else { return nil }
        return ["id": .string(id), "answers": .array(answers)]
    }
}
#endif
