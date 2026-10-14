#if os(macOS)
import CueStore
import Darwin
import Foundation

// 终端会话（钩子）与托管会话（stream-json）共用的：模型与强度、会话文件、权限确认与提问怎么问怎么答。

extension PiSession {
    /// Claude Code 的会话：`<会话 id>.<进程 pid>`。
    static func claudeID(sessionID: String, pid: Int32) -> String { "\(sessionID).\(pid)" }
}

enum ClaudeCode {
    /// 模型的提供方写成 Agent 自己：Claude Code 的模型名（`opus`、`mimo-v2.5`）在它自己的命名空间里
    static let provider = AgentKind.claudeCode.modelProvider!

    static func model(_ id: String, name: String? = nil, levels: [PiThinkingLevel] = []) -> PiModelOption {
        PiModelOption(key: PiModelKey(provider: provider, id: id), name: name ?? id, thinkingLevels: levels)
    }

    /// Claude Code 的强度档（`--effort`、`effortLevel`）：没有关掉思考的档，更低的夹到 low。
    static let efforts: [PiThinkingLevel] = [.low, .medium, .high, .xhigh, .max]

    static func effort(_ level: PiThinkingLevel) -> String { level.clamped(to: efforts).rawValue }

    /// 会话文件：`<配置目录>/projects/<工作目录的真实路径，非字母数字换成 ->/<会话 id>.jsonl`。
    static func sessionFile(home: URL, cwd: URL, sessionID: String) -> URL {
        let encoded = String(decoding: realPath(cwd).utf16.map { unit -> UInt16 in
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) ? unit : 0x2D
        }, as: UTF16.self)
        return home.appending(path: "projects/\(encoded)/\(sessionID).jsonl")
    }

    /// Claude Code 记的工作目录是解析过符号链接的真实路径（/tmp 是 /private/tmp）。`URL.resolvingSymlinksInPath` 会去掉 /private，不用它。
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// 一次等你回答：Claude Code 要用一个工具（钩子的 `PermissionRequest`、托管进程的 `can_use_tool`），或问你一个问题（`AskUserQuestion`：
/// 终端会话经 `PreToolUse` 钩子答，托管进程经 `can_use_tool`；答案就是放行时改写的输入里的 `answers`）。
/// 提问只有一个单选问题时能从 CuePad 作答，多个问题或多选只能在终端里答（问题照样显示）。
struct ClaudePermission {
    let promptID = UUID().uuidString
    let tool: String
    let input: JSONValue

    private static let textLimit = 500

    var isQuestion: Bool { tool == "AskUserQuestion" }

    private var asked: (question: String, options: [String])? {
        guard isQuestion, let questions = input["questions"]?.array, let first = questions.first,
              let question = first["question"]?.string else { return nil }
        return (question, first["options"]?.array?.compactMap { $0["label"]?.string } ?? [])
    }

    /// 能从 CuePad 答（权限确认都能；提问只有一个单选问题的能）
    var answerable: Bool {
        !isQuestion || (input["questions"]?.array?.count == 1 && input["questions"]?.array?.first?["multiSelect"]?.bool != true)
    }

    /// 显示的问题；`answerable` 为 false 或交给终端时没有作答标识（只显示）。
    func question(answerable: Bool = true) -> PiQuestion {
        let id = answerable && self.answerable ? promptID : nil
        if let asked {
            let header = input["questions"]?.array?.first?["header"]?.string
            let text = [header, asked.question].compactMap { $0 }.joined(separator: "\n")
            // 终端里每道选择题都有"自己填"（Type something）
            return PiQuestion(promptID: id, kind: .select, text: ToolDetail.clip(text, Self.textLimit), options: asked.options, allowsOther: true)
        }
        let text = ["允许 Claude Code 使用 \(tool)？", ToolDetail.target(input), input["description"]?.string]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n")
        return PiQuestion(promptID: id, kind: .confirm, text: ToolDetail.clip(text, Self.textLimit))
    }

    /// 作答写成 Claude Code 的决定（`{behavior, updatedInput}` 或 `{behavior: deny, message}`）；答案对不上抛 `rejected("bad_answer")`。
    func decision(_ answer: PiAnswerValue, to id: String) throws -> JSONValue {
        if isQuestion { return ["behavior": "allow", "updatedInput": try answered(answer, to: id)] }
        guard id == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        switch answer {
        case .confirmed(true): return ["behavior": "allow", "updatedInput": input]
        case .confirmed(false): return ["behavior": "deny", "message": "用户在 CuePad 里拒绝了"]
        default: throw PiBridgeError.rejected("bad_answer")
        }
    }

    /// 提问的作答：原样的输入加上 `answers`（问题 → 选中的选项）。
    func answered(_ answer: PiAnswerValue, to id: String) throws -> JSONValue {
        guard id == promptID, answerable else { throw PiBridgeError.rejected("stale_prompt") }
        guard let asked, case .object(var updated) = input else { throw PiBridgeError.rejected("bad_answer") }
        let chosen: String
        switch answer {
        case .option(let label) where asked.options.contains(label): chosen = label
        case .text(let text) where !text.isEmpty: chosen = text
        default: throw PiBridgeError.rejected("bad_answer")
        }
        updated["answers"] = [asked.question: .string(chosen)]
        return .object(updated)
    }
}
#endif
