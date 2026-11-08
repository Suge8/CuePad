import CueStore
import Foundation

/// 回复框里的斜杠命令（iOS 与 Mac 共用）：输入 "/" 弹出的面板列哪些命令，输入框里的内容算不算一条命令。
/// 命令清单来自会话所在目录的目录记录（`AgentCatalog.commands`，Agent 随会话上报，同步到手机）。
/// 送达各家一条规则：提示词模板与技能展开成你的一句话（`speaks`），同别的话走投送方式 `send`——带着请求 id 交出，展开后落成的那条消息带着它，
/// 气泡等对话里出现这句再换下，送达同说话；其余是命令（`command`，内置与扩展命令），不产生你的话，以 Agent 执行了它为送达，进度在回复框上方一行。
nonisolated enum PiSlash {
    /// 面板此刻要列的命令；输入框里不是 "/名字片段" 的形态（不以 / 开头、已经在写参数）时为 nil，面板不出现。
    /// 按相关度排：名字以片段开头的在前，名字里含有的其次，说明里含有的最后；同一档里内置在前，其次扩展、提示词模板、技能，各自保持清单顺序。
    static func matches(_ text: String, in commands: [PiSlashCommand]) -> [PiSlashCommand]? {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) else { return nil }
        let query = String(text.dropFirst()).lowercased()
        let ranked = commands.enumerated().compactMap { index, command -> (rank: Int, source: Int, index: Int, command: PiSlashCommand)? in
            guard let rank = rank(command, query: query) else { return nil }
            return (rank, order(command.source), index, command)
        }
        return ranked.sorted { ($0.rank, $0.source, $0.index) < ($1.rank, $1.source, $1.index) }.map { $0.command }
    }

    private static func rank(_ command: PiSlashCommand, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let name = command.name.lowercased()
        if name.hasPrefix(query) { return 0 }
        if name.contains(query) { return 1 }
        if command.summary?.lowercased().contains(query) == true { return 2 }
        return nil
    }

    private static func order(_ source: Open<PiCommandSource>) -> Int {
        switch source {
        case .known(.builtin): 0
        case .known(.extension): 1
        case .known(.prompt): 2
        case .known(.skill): 3
        case .unknown: 4
        }
    }

    /// 选中一条命令后输入框里的内容：斜杠加名字加一个空格，接着写参数。
    static func insertion(for command: PiSlashCommand) -> String { "/\(command.name) " }

    /// 草稿是一条命令（清单里不是 `speaks` 的那些）时，要发出的整行；否则为 nil（当你说的话发，模板与技能也是）。
    /// 命令行是输入的文字（首个词是清单里的名字），带上的卡片文字接在后面当参数（发给 Agent 时）；带图片的不算命令，命令不能携带图片。
    @MainActor static func line(of draft: ComposerDraft, in commands: [PiSlashCommand], for session: PiSessionState) -> String? {
        // 回复框每次重算都问一遍：先只看开头，是命令再整串修剪（长草稿每次都整串复制一遍，打一个字就要几毫秒）
        let start = draft.text.drop { $0.isWhitespace }
        guard start.hasPrefix("/"), !draft.hasFiles else { return nil }
        let name = start.dropFirst().prefix { !$0.isWhitespace }
        guard commands.contains(where: { $0.name == name && !speaks($0, in: session) }) else { return nil }
        return invocation(start, then: draft.attachments.map(\.content))
    }

    /// 草稿是用模板或技能说的一句（清单里 `speaks` 的那些）时它的存储格式正文：Agent 只认开头的 `/名字`，所以你打的那行排最前，
    /// 带上的卡片与批注接在后面当参数（`invocation`），附件在最后。不是时为 nil（按 `ComposerDraft.stored` 发）。
    @MainActor static func said(_ draft: ComposerDraft, in commands: [PiSlashCommand], for session: PiSessionState) -> String? {
        let start = draft.text.drop { $0.isWhitespace }
        guard start.hasPrefix("/") else { return nil }
        let name = start.dropFirst().prefix { !$0.isWhitespace }
        guard commands.contains(where: { $0.name == name && speaks($0, in: session) }) else { return nil }
        return StoredBody.make(text: invocation(start, then: draft.attachments.map(\.content) + [ReplyNote.message(draft.notes, said: "")]), files: draft.files)
    }

    /// `/名字` 后紧跟一个空格，再接你打的参数与 `more`（各成一段）：Pi 认扩展命令与技能的名字只到第一个空格，
    /// 名字后直接换行会把参数并进名字里，认不出就当普通文字交给模型。
    private static func invocation(_ typed: Substring, then more: [String]) -> String {
        let name = typed.prefix { !$0.isWhitespace }
        let arguments = typed.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = ([arguments] + more).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return rest.isEmpty ? String(name) : "\(name) \(rest)"
    }

    /// 这条命令是你说的话：提示词模板与技能，且这家说话时能把它连同请求 id 交出——Pi 由桥扩展展开（`expandPromptTemplates`），
    /// Codex 在 `CodexRuntime` 里认 `skill:`。OpenCode 的命令端点不收消息 id（展开出的那条认不回请求，气泡会一直挂着），
    /// 它的模板仍是命令，以端点执行完的回执为送达；Claude Code、Grok Build、dsh 报的命令都是内置。
    static func speaks(_ command: PiSlashCommand, in session: PiSessionState) -> Bool {
        guard session.agent != .known(.opencode) else { return false }
        return command.source == .known(.prompt) || command.source == .known(.skill)
    }
}

/// 上下文用量条的读数（同一份规则：颜色档位、文案、是否建议压缩）。刚压缩过、Pi 在下次回答前不知道已用多少时没有读数
/// （`init?` 给 nil，界面不画这颗胶囊：一道短横或"未知"读着像减号、像控件）。
nonisolated struct PiContextMeter: Equatable {
    /// 已用到这个比例建议压缩（用量条的说明里给"压缩"）
    static let compactFraction = 0.8

    /// 已用的比例，0 到 1。
    let fraction: Double

    init?(_ usage: PiContextUsage) {
        guard let fraction = usage.fraction else { return nil }
        self.fraction = fraction
    }

    /// 用量到了哪一档：上下文与订阅额度（`QuotaMeter`）同一个口径。
    var level: UsageLevel { UsageLevel(used: fraction) }

    var suggestsCompact: Bool { fraction >= Self.compactFraction }

    private var used: Int { Int((fraction * 100).rounded()) }

    /// 胶囊里"上下文"后面的小字："21%"。
    var percent: String { "\(used)%" }

    /// 悬停与读屏：先说这是上下文，快满了时说可以压缩。
    var help: Dotted { Dotted(String(localized: "上下文")) + summary + Dotted(suggestsCompact ? String(localized: "快满了，可以压缩") : nil) }

    /// "已用 21% · 剩 79%"（只写比例，用户看不到 token 数）。
    var summary: Dotted { Dotted(String(localized: "已用 \(used)%"), String(localized: "剩 \(100 - used)%")) }
}
