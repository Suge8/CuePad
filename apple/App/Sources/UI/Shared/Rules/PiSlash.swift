import CueStore
import Foundation

/// 回复框里的斜杠命令（iOS 与 Mac 共用）：输入 "/" 弹出的面板列哪些命令，输入框里的内容算不算一条命令。
/// 命令清单来自会话（`PiSessionState.commands`，扩展随会话上报，同步到手机）；命令由 Pi 派发执行（投送方式 `command`）。
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

    /// 草稿是一条已知的斜杠命令时，要发出的整行；否则为 nil（当普通消息发）。
    /// 命令行是输入的文字（首个词是清单里的名字），带上的卡片文字接在后面当参数（交给 Agent 时）；带图片的不算命令，命令不能携带图片。
    @MainActor static func line(of draft: ComposerDraft, in commands: [PiSlashCommand]) -> String? {
        let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.hasPrefix("/"), !draft.hasImages else { return nil }
        let name = typed.dropFirst().prefix { !$0.isWhitespace }
        guard commands.contains(where: { $0.name == name }) else { return nil }
        return ([typed] + draft.attachments.map(\.content)).joined(separator: "\n\n")
    }
}

/// 上下文用量条的读数（同一份规则：颜色档位、文案、是否建议压缩）。
nonisolated struct PiContextMeter: Equatable {
    enum Level: Equatable {
        /// 余量充足
        case roomy
        /// 已用超过七成
        case tight
        /// 已用超过九成，接近自动压缩
        case critical
        /// 刚压缩过，Pi 在下次回答前不知道已用多少
        case unknown
    }

    static let tightFraction = 0.7
    static let criticalFraction = 0.9
    /// 已用到这个比例建议压缩（用量条的说明里给"压缩"）
    static let compactFraction = 0.8

    let usage: PiContextUsage

    init(_ usage: PiContextUsage) { self.usage = usage }

    var fraction: Double? { usage.fraction }
    var remaining: Int? { usage.tokens.map { max(0, usage.window - $0) } }

    var level: Level {
        guard let fraction else { return .unknown }
        return fraction >= Self.criticalFraction ? .critical : fraction >= Self.tightFraction ? .tight : .roomy
    }

    var suggestsCompact: Bool { (fraction ?? 0) >= Self.compactFraction }

    /// 用量条旁的小字："21%"；未知时是一道横线。
    var percent: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// 悬停与读屏：先说这是上下文，快满了时说可以压缩。
    var help: Dotted { Dotted("上下文") + summary + Dotted(suggestsCompact ? "快满了，可以压缩" : nil) }

    /// "已用 21% · 剩 158k tokens"；未知时说明为什么。
    var summary: Dotted {
        guard let fraction, let remaining else { return Dotted("刚压缩过", "下次回答后更新（窗口 \(Self.abbreviated(usage.window)) tokens）") }
        return Dotted("已用 \(Int((fraction * 100).rounded()))%", "剩 \(Self.abbreviated(remaining)) tokens")
    }

    /// 3 位有效数字内的简写：950、9.5k、158k、1.2M。
    static func abbreviated(_ count: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        switch count {
        case ..<1_000: return String(count)
        case ..<10_000: return trimmed(Double(count) / 1_000) + "k"
        case ..<1_000_000: return String(Int((Double(count) / 1_000).rounded())) + "k"
        default: return trimmed(Double(count) / 1_000_000) + "M"
        }
    }
}
