import CueStore
import Foundation

/// 回复框里的斜杠命令（iOS 与 Mac 共用）：输入 "/" 弹出的面板列哪些命令，输入框里的内容算不算一条命令。
/// 命令清单来自会话所在目录的目录记录（`AgentCatalog.commands`，Agent 随会话上报，同步到手机）；命令由 Pi 派发执行（投送方式 `command`）。
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
    /// 命令行是输入的文字（首个词是清单里的名字），带上的卡片文字接在后面当参数（发给 Agent 时）；带图片的不算命令，命令不能携带图片。
    @MainActor static func line(of draft: ComposerDraft, in commands: [PiSlashCommand]) -> String? {
        // 回复框每次重算都问一遍：先只看开头，是命令再整串修剪（长草稿每次都整串复制一遍，打一个字就要几毫秒）
        let start = draft.text.drop { $0.isWhitespace }
        guard start.hasPrefix("/"), !draft.hasImages else { return nil }
        let name = start.dropFirst().prefix { !$0.isWhitespace }
        guard commands.contains(where: { $0.name == name }) else { return nil }
        let typed = start.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([typed] + draft.attachments.map(\.content)).joined(separator: "\n\n")
    }
}

/// 上下文用量条的读数（同一份规则：颜色档位、文案、是否建议压缩）。刚压缩过、Pi 在下次回答前不知道已用多少时没有读数
/// （`init?` 给 nil，界面不画这颗胶囊：一道短横或"未知"读着像减号、像控件）。
nonisolated struct PiContextMeter: Equatable {
    enum Level: Equatable {
        /// 余量充足
        case roomy
        /// 已用超过七成
        case tight
        /// 已用超过九成，接近自动压缩
        case critical
    }

    static let tightFraction = 0.7
    static let criticalFraction = 0.9
    /// 已用到这个比例建议压缩（用量条的说明里给"压缩"）
    static let compactFraction = 0.8

    /// 已用的比例，0 到 1。
    let fraction: Double

    init?(_ usage: PiContextUsage) {
        guard let fraction = usage.fraction else { return nil }
        self.fraction = fraction
    }

    var level: Level { Self.level(of: fraction) }

    /// 用量到了哪一档：上下文与订阅额度（`QuotaMeter`）同一个口径。
    static func level(of fraction: Double) -> Level {
        fraction >= criticalFraction ? .critical : fraction >= tightFraction ? .tight : .roomy
    }

    var suggestsCompact: Bool { fraction >= Self.compactFraction }

    private var used: Int { Int((fraction * 100).rounded()) }

    /// 胶囊里"上下文"后面的小字："21%"。
    var percent: String { "\(used)%" }

    /// 悬停与读屏：先说这是上下文，快满了时说可以压缩。
    var help: Dotted { Dotted("上下文") + summary + Dotted(suggestsCompact ? "快满了，可以压缩" : nil) }

    /// "已用 21% · 剩 79%"（只写比例，用户看不到 token 数）。
    var summary: Dotted { Dotted("已用 \(used)%", "剩 \(100 - used)%") }
}
