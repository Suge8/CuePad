import Foundation

/// 要整理的一件（`AgentLibrary.tidies`）：只有问题时出现，每件一句事实（`title`）一个动作（`action`）。判定规则在 CuePi 的
/// `LibrarySkillScan`、`LibraryInstructionScan`；整理不弹确认，移走的进系统废纸篓，做完给一条可撤销的提示。
/// `id` 由种类推出（同名的带名字、格式不对的带路径、项目的带项目），重扫后不变；整理请求（`TidyOrder`）按它指认，
/// 照执行时的文件做（那时多出来的同类问题一并做），那件已不在就不做（一件都不在时 `AgentLibraryError.tidyGone`）。
public struct LibraryTidy: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let kind: Kind

  public init(id: String, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  public enum Kind: Codable, Equatable, Sendable {
    /// 旧目录里的技能（各家自己的技能目录、项目里 .claude/.pi/.codex/.opencode 下的，不是 CuePad 写的、不是各家自管的）：搬进同范围的 `.agents/skills`
    case stray([SkillMove])
    /// Claude Code 看不见（不读 `.agents`）：缺逐个技能的相对链接，链上
    case unlinked([SkillEntry])
    /// 同名（全局与项目之间、同一范围内都不许）：比一比、留一份，其余进废纸篓
    case duplicate(name: String, copies: [SkillCopy])
    /// 格式不对（取四家最严）：打开它自己改
    case malformed(SkillEntry, SkillProblem)
    /// 技能目录里的空目录：移走
    case empty([String])
    /// 各家的全局说明各写一份：内容不同的比一比、合成一份全局说明，各家换成链到它的链接；同内容的直接换链接
    case globalInstructions([InstructionSource])
    /// 项目里另有不同的 CLAUDE.md（有它 Claude Code 就不读 AGENTS.md）：合成进 AGENTS.md，CLAUDE.md 移走
    case projectClaude(project: UUID, sources: [InstructionSource])
  }

  /// 按什么动：界面的按钮。
  public enum Action: Sendable {
    case move, link, compare, open, trash, merge

    public var title: String {
      switch self {
      case .move: String(localized: "搬过去")
      case .link: String(localized: "链上")
      case .compare: String(localized: "比一比")
      case .open: String(localized: "打开")
      case .trash: String(localized: "移走")
      case .merge: String(localized: "合成")
      }
    }
  }

  public var action: Action {
    switch kind {
    case .stray: .move
    case .unlinked: .link
    case .duplicate: .compare
    case .malformed: .open
    case .empty: .trash
    case .globalInstructions: differs ? .compare : .link
    case .projectClaude: .merge
    }
  }

  /// "全部整理"做不做它：同名要你挑留哪份、格式不对要你自己改，不做；内容不同的说明照合成稿（`merged`）做。
  public var isAutomatic: Bool {
    switch kind {
    case .duplicate, .malformed: false
    default: true
    }
  }

  /// 要合成的几份内容不止一种（比一比才有意义）。
  public var differs: Bool { Set(sources.compactMap(\.text)).count > 1 }

  /// 说明的来源（合成的两种）；其余为空。
  public var sources: [InstructionSource] {
    switch kind {
    case .globalInstructions(let sources), .projectClaude(_, let sources): sources
    default: []
    }
  }

  /// 合成稿：几份说明按段取并集（`InstructionMerge`），整理时照它写进 AGENTS.md；不是说明的为 nil。
  /// 替换基础提示的两份（`InstructionSource.Origin.replacesBasePrompt`）只有撤掉的（`retiring`，同 `TidyOrder.retire`）才并进来。
  public func merged(retiring: Set<InstructionSource.Origin> = []) -> String? {
    let used = sources.filter { !$0.origin.replacesBasePrompt || retiring.contains($0.origin) }
    return used.isEmpty ? nil : InstructionMerge.union(used.compactMap(\.text))
  }

  /// 一句事实（各端按自己的语言写，参数是名字与个数）。
  public var title: String {
    switch kind {
    case .stray(let moves):
      moves.count == 1 ? String(localized: "「\(moves[0].skill.name)」在旧目录里") : String(localized: "\(moves.count) 个技能在旧目录里")
    case .unlinked(let skills): String(localized: "Claude Code 看不见 \(skills.count) 个技能")
    case .duplicate(let name, let copies): String(localized: "\(copies.count) 个技能都叫 \(name)")
    case .malformed(let skill, _): String(localized: "「\(skill.name)」的格式不对")
    case .empty(let directories):
      directories.count == 1 ? String(localized: "技能目录里有个空目录") : String(localized: "技能目录里有 \(directories.count) 个空目录")
    case .globalInstructions(let sources):
      differs
        ? String(localized: "\(Set(sources.compactMap(\.origin.agent)).count) 家的全局规则各写一份")
        : String(localized: "全局说明换成一份、各家链到它")
    case .projectClaude: String(localized: "项目里另有一份不同的 CLAUDE.md")
    }
  }
}

/// 一个技能所在（要整理里列出的）：名字取目录名。
public struct SkillEntry: Codable, Hashable, Sendable {
  public let name: String
  public let scope: LibraryScope
  /// 技能目录的绝对路径
  public let path: String

  public init(name: String, scope: LibraryScope, path: String) {
    self.name = name
    self.scope = scope
    self.path = path
  }
}

/// 旧目录里的一个技能搬到哪（`to` 是同范围 `.agents/skills` 下的目录）。
public struct SkillMove: Codable, Hashable, Sendable {
  public let skill: SkillEntry
  public let to: String

  public init(skill: SkillEntry, to: String) {
    self.skill = skill
    self.to = to
  }
}

/// 同名技能的一份：比一比要看的正文（SKILL.md）。
public struct SkillCopy: Codable, Equatable, Sendable {
  public let skill: SkillEntry
  public let text: String
  public let modifiedAt: Date

  public init(skill: SkillEntry, text: String, modifiedAt: Date) {
    self.skill = skill
    self.text = text
    self.modifiedAt = modifiedAt
  }
}

/// 技能的格式哪里不对（四家最严的那条）。
public enum SkillProblem: Codable, Equatable, Sendable, CustomStringConvertible {
  /// SKILL.md 读不出、没有开头的 `---` 信息块
  case unreadable
  /// `name` 与目录名不同
  case nameMismatch(String)
  /// 名字只能是小写字母、数字与连字符，最多 64 个字
  case badName
  /// 没有 description，或超过 1024 个字
  case badDescription
  /// 嵌套超过 6 层（Codex 读不到、不报错）
  case tooDeep

  public var description: String {
    switch self {
    case .unreadable: String(localized: "SKILL.md 开头没有 --- 包着的名字与说明")
    case .nameMismatch(let name): String(localized: "name 写的是 \(name)，和目录名不一样")
    case .badName: String(localized: "名字只能用小写字母、数字和连字符，最多 64 个字")
    case .badDescription: String(localized: "description 要有，且不超过 1024 个字")
    case .tooDeep: String(localized: "放得太深（超过 6 层），Codex 读不到")
    }
  }
}

/// 要合成的一份说明。
public struct InstructionSource: Codable, Equatable, Sendable {
  public enum Origin: Codable, Hashable, Sendable {
    /// 大家共读的那份：全局的 `~/.agents/AGENTS.md`、项目的 `AGENTS.md`
    case shared
    /// 这家自己的那份：全局的 `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`……，项目的 `CLAUDE.md`
    case agent(AgentKind)
    /// Pi 的 `SYSTEM.md`（替换它的基础提示）：只作比对来源，合成时可选进废纸篓；留着时仍是说明里单独的一份（`LibraryInstruction.Kind.piSystem`）
    case piSystem
    /// Codex 配置里 `model_instructions_file` 指的那份（替换它的基础提示）：只作比对来源，合成时可选撤掉这个键
    case codexPrompt

    /// 替换基础提示的两份：自己不算"各写一份"，合成时撤不撤由你选（`TidyOrder.retire`）。
    public var replacesBasePrompt: Bool { self == .piSystem || self == .codexPrompt }

    /// 是哪家的；共读的那份为 nil。
    public var agent: AgentKind? {
      switch self {
      case .shared: nil
      case .agent(let kind): kind
      case .piSystem: .pi
      case .codexPrompt: .codex
      }
    }
  }

  public let origin: Origin
  public let path: String
  /// 正文；共读的那份还没有时为 nil
  public let text: String?
  public let modifiedAt: Date?

  public init(origin: Origin, path: String, text: String?, modifiedAt: Date?) {
    self.origin = origin
    self.path = path
    self.text = text
    self.modifiedAt = modifiedAt
  }
}

/// 几份说明合成一份：以第一份为底，其余各份里底稿没有的段落（空行隔开，忽略首尾空白）插在它前面那段之后，顺序照原文。
/// 合成稿之后在编辑页里改；不猜哪一份对。
public enum InstructionMerge {
  public static func union(_ texts: [String]) -> String {
    var merged: [String] = []
    for text in texts {
      var anchor = merged.count - 1
      for block in blocks(of: text) {
        if let found = merged.firstIndex(where: { normalized($0) == normalized(block) }) {
          anchor = found
        } else {
          merged.insert(block, at: anchor + 1)
          anchor += 1
        }
      }
    }
    return merged.joined(separator: "\n\n") + (merged.isEmpty ? "" : "\n")
  }

  static func blocks(of text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: /\n[ \t]*\n/)
      .map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  private static func normalized(_ block: String) -> String {
    block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
