#if os(macOS)
import CueStore
import Darwin
import Foundation

// 终端会话（钩子）与托管会话（stream-json）共用的规则：状态怎么切、工具怎么写成一句话、权限确认与提问怎么问怎么答。

extension PiWorkState {
    /// 粗状态（状态起点只在它变的时候前进）：工作中、等你确认、出错、空闲。
    var phase: Int {
        if isWorking { return 0 }
        switch self {
        case .waitingForUser: return 1
        case .error: return 2
        default: return 3
        }
    }
}

extension PiSession {
    /// 进入 `next`：粗状态（`PiWorkState.phase`）变了才换 `stateSince`；离开空闲起记 `busySince`，
    /// 中间等你确认不断，歇下、出错时清掉。与 Pi 扩展的计时同一规则。
    mutating func enter(_ next: PiWorkState, detail: String? = nil, at now: Date = .now) {
        if next.phase != state.phase { stateSince = now }
        busySince = next.isWorking || next == .waitingForUser ? busySince ?? now : nil
        if next != .error { errorMessage = nil }
        state = next
        self.detail = detail
    }

    /// 换上终端信息（启动时从会话列表补上的会话，第一次钩子才带来终端的环境变量）。
    func with(terminal: PiTerminal) -> PiSession {
        var session = PiSession(
            id: id, sessionID: sessionID, agent: agent, sessionFile: sessionFile, pid: pid, cwd: cwd, terminal: terminal,
            extensionVersion: extensionVersion, state: state, detail: detail, errorMessage: errorMessage, stateSince: stateSince, busySince: busySince)
        session.name = name
        session.firstMessage = firstMessage
        session.question = question
        session.launchToken = launchToken
        session.subagents = subagents
        session.hosted = hosted
        session.model = model
        session.thinking = thinking
        session.availableModels = availableModels
        session.context = context
        session.commands = commands
        return session
    }

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

    // MARK: 工具

    private static let detailLimit = 120

    /// 正在调的工具写成一句话（同 Pi 扩展）："工具名 · 目标"：命令、搜索取首个非空行，文件取文件名。
    static func toolDetail(_ name: String, _ input: ClaudeJSON?) -> String {
        guard let target = toolTarget(input) else { return name }
        return name + PiSessionState.detailSeparator + target
    }

    static func toolTarget(_ input: ClaudeJSON?) -> String? {
        let line = ["command", "pattern", "query", "url", "description"].lazy.compactMap { input?[$0]?.string }.first.flatMap(firstLine)
        let file = (input?["file_path"]?.string ?? input?["path"]?.string ?? input?["notebook_path"]?.string).map { URL(filePath: $0).lastPathComponent }
        return (line ?? file).map { clip($0, detailLimit) }
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: 子代理

    static func subagent(name: String, role: String, at now: Date) -> PiSubagentState {
        PiSubagentState(name: name.isEmpty ? role : name, role: role, phase: .known(.running), startedAt: now)
    }

    static func settle(_ agent: inout PiSubagentState, _ phase: PiSubagentPhase, summary: String?, at now: Date) {
        agent.phase = .known(phase)
        agent.action = summary.flatMap(firstLine).map { clip($0, detailLimit) } ?? ""
        agent.settledAt = now
    }
}

/// 一次等你确认：Claude Code 要用一个工具（钩子的 `PermissionRequest`、托管进程的 `can_use_tool`）。
/// `AskUserQuestion` 也走这里：答案就是放行时改写的输入里的 `answers`。只有一个单选问题时能从 CuePad 作答，
/// 多个问题或多选只能在终端里答（问题照样显示）。
struct ClaudePermission {
    let promptID = UUID().uuidString
    let tool: String
    let input: ClaudeJSON

    private static let textLimit = 500

    private var asked: (question: String, options: [String])? {
        guard tool == "AskUserQuestion", let questions = input["questions"]?.array, let first = questions.first,
              let question = first["question"]?.string else { return nil }
        return (question, first["options"]?.array?.compactMap { $0["label"]?.string } ?? [])
    }

    private var answerable: Bool {
        tool != "AskUserQuestion" || (input["questions"]?.array?.count == 1 && input["questions"]?.array?.first?["multiSelect"]?.bool != true)
    }

    var question: PiQuestion {
        if let asked {
            let header = input["questions"]?.array?.first?["header"]?.string
            let text = [header, asked.question].compactMap { $0 }.joined(separator: "\n")
            return PiQuestion(promptID: answerable ? promptID : nil, kind: .select, text: ClaudeCode.clip(text, Self.textLimit), options: asked.options)
        }
        let text = ["允许 Claude Code 使用 \(tool)？", ClaudeCode.toolTarget(input), input["description"]?.string]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n")
        return PiQuestion(promptID: promptID, kind: .confirm, text: ClaudeCode.clip(text, Self.textLimit))
    }

    /// 等你确认时会话的一句话说明：问题的第一行
    var title: String { ClaudeCode.firstLine(question.text) ?? tool }

    /// 作答写成 Claude Code 的决定（`{behavior, updatedInput}` 或 `{behavior: deny, message}`）；答案对不上抛 `rejected("bad_answer")`。
    func decision(_ answer: PiAnswerValue, to id: String) throws -> ClaudeJSON {
        guard id == promptID, answerable else { throw PiBridgeError.rejected("stale_prompt") }
        switch (asked, answer) {
        case (let asked?, .option(let label)) where asked.options.contains(label):
            guard case .object(var updated) = input else { throw PiBridgeError.rejected("bad_answer") }
            updated["answers"] = [asked.question: .string(label)]
            return ["behavior": "allow", "updatedInput": .object(updated)]
        case (nil, .confirmed(true)):
            return ["behavior": "allow", "updatedInput": input]
        case (nil, .confirmed(false)):
            return ["behavior": "deny", "message": "用户在 CuePad 里拒绝了"]
        default:
            throw PiBridgeError.rejected("bad_answer")
        }
    }
}
#endif
