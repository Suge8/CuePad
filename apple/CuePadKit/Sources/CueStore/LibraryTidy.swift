import Foundation

/// 该整理的一件（`AgentLibrary.tidies`），只在有问题时出现。判定规则在 CuePi 的 `LibrarySkillScan`、`LibraryInstructionScan`。
/// 动作只有三个：一键整理（不用你选的那几件，`isAutomatic`）、去重（同名的在技能的文件页里只留一份，`TidyOrder.keep`）、
/// 合并（内容不同的规则在规则的文件页里合并进来，`merges`）。不弹确认，移走的进系统废纸篓，本机做完给一条可撤销的提示。
/// `id` 由种类推出（同名的带名字、项目的带项目），重扫后不变；整理请求（`TidyOrder`）按它指认，
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
    /// Claude Code 读不到（不读 `.agents`）：缺逐个技能的相对链接，补上
    case unlinked([SkillEntry])
    /// 同名（全局与项目之间、同一范围内都不许）：去重，留一份，其余进废纸篓；各份都列在技能里（`AgentLibrary.skills`）
    case duplicate(name: String, copies: [SkillEntry])
    /// 技能目录里的空目录：移走
    case empty([String])
    /// 各家的全局规则各写一份：内容不同的合并成一份全局规则（`merges`），各家换成链到它的链接；同内容的直接换链接
    case globalInstructions([InstructionSource])
    /// Claude Code 读不到项目的 AGENTS.md（同层另有 CLAUDE.md、`.claude/CLAUDE.md` 或个人的 CLAUDE.local.md）：内容不同的合并进 AGENTS.md，
    /// 那两份移走、CLAUDE.md 换成链到 AGENTS.md 的链接（同全局）；只是个人那份挡着、或内容一样时只换链接
    case projectClaude(project: UUID, sources: [InstructionSource])
  }

  /// 一键整理做不做它：同名要你挑留哪份、内容不同的规则要你看过再合并，不做。
  public var isAutomatic: Bool {
    switch kind {
    case .duplicate: false
    case .globalInstructions, .projectClaude: !merges
    case .stray, .unlinked, .empty: true
    }
  }

  /// 内容不同、要合并的规则（在那份规则的文件页里"合并进来"）。替换基础提示的两份只作比对，自己不算不同。
  public var merges: Bool {
    switch kind {
    case .globalInstructions: Set(sources.filter { !$0.origin.replacesBasePrompt }.compactMap(\.hash)).count > 1
    case .projectClaude: sources.contains { $0.origin == .agent(.claudeCode) }
    default: false
    }
  }

  /// 说的是哪份规则；技能的为 nil。
  public var instruction: LibraryInstruction.Kind? {
    switch kind {
    case .globalInstructions: .global
    case .projectClaude(let project, _): .project(project)
    default: nil
    }
  }

  /// 另写了一份的几家（替换基础提示的两份不算），按 `AgentKind` 的顺序。
  public var writers: [AgentKind] {
    let own = Set(sources.filter { !$0.origin.replacesBasePrompt }.compactMap(\.origin.agent))
    return AgentKind.allCases.filter(own.contains)
  }

  /// 规则的来源（合并的两种）；其余为空。
  public var sources: [InstructionSource] {
    switch kind {
    case .globalInstructions(let sources), .projectClaude(_, let sources): sources
    default: []
    }
  }

  /// 合并稿：几份规则按段取并集（`InstructionMerge`），整理时照它写进 AGENTS.md；不是规则的为 nil。`texts` 是各份的正文（路径 → 正文，
  /// Mac 上是刚读的文件，手机上是同步来的 `LibraryFileText`）。
  /// 替换基础提示的两份（`InstructionSource.Origin.replacesBasePrompt`）只有撤掉的（`retiring`，同 `TidyOrder.retire`）才并进来。
  public func merged(retiring: Set<InstructionSource.Origin> = [], texts: [String: String]) -> String? {
    let used = sources.filter { $0.hash != nil && (!$0.origin.replacesBasePrompt || retiring.contains($0.origin)) }
    return used.isEmpty ? nil : InstructionMerge.union(used.compactMap { texts[$0.path] })
  }

  /// 合并稿按段，标出共读的那份里没有、会并进来的段（合并前给你看）。
  public func preview(retiring: Set<InstructionSource.Origin>, texts: [String: String]) -> [(text: String, incoming: Bool)] {
    let shared = sources.first { $0.origin == .shared }.flatMap { texts[$0.path] } ?? ""
    let blocks = Set(InstructionMerge.blocks(of: shared).map(InstructionMerge.normalized))
    return InstructionMerge.blocks(of: merged(retiring: retiring, texts: texts) ?? "").map { ($0, !blocks.contains(InstructionMerge.normalized($0))) }
  }
}

/// 一个技能所在（整理里列出的）：名字取目录名。
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

/// 技能的格式哪里不对（四家最严的那条）。
public enum SkillProblem: Codable, Equatable, Sendable, CustomStringConvertible {
  /// SKILL.md 读不出（不是 UTF-8 文本、没有权限）或开头没有 `---` 包着的名字与说明
  case unreadable
  /// `name` 与目录名不同
  case nameMismatch(String)
  /// 名字只能是小写字母、数字与连字符，最多 64 个字
  case badName
  /// 没有 description，或超过 1024 个字
  case badDescription
  /// 嵌套超过 6 层（Codex 读不到、不报错）
  case tooDeep

  /// 写在文件页哪个输入框下面（`tooDeep` 说的是放在哪，不在哪个框上）。
  public enum Field: Sendable { case name, description }

  public var field: Field? {
    switch self {
    case .unreadable, .nameMismatch, .badName: .name
    case .badDescription: .description
    case .tooDeep: nil
    }
  }

  public var description: String {
    switch self {
    case .unreadable: String(localized: "读不出 name 与 description")
    case .nameMismatch: String(localized: "要和文件夹名一样")
    case .badName: String(localized: "文件夹名只能用小写字母、数字和连字符，最多 64 个字")
    case .badDescription: String(localized: "要有，且不超过 1024 个字")
    case .tooDeep: String(localized: "放得太深（超过 6 层），Codex 读不到")
    }
  }
}

/// 要合并的一份规则。
public struct InstructionSource: Codable, Equatable, Sendable {
  public enum Origin: Codable, Hashable, Sendable {
    /// 大家共读的那份：全局的 `~/.agents/AGENTS.md`、项目的 `AGENTS.md`
    case shared
    /// 这家自己的那份：全局的 `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`……，项目的 `CLAUDE.md`
    case agent(AgentKind)
    /// Pi 的 `SYSTEM.md`（替换它的基础提示）：只作比对来源，合并时可选进废纸篓；留着时仍是规则里单独的一份（`LibraryInstruction.Kind.piSystem`）
    case piSystem
    /// Codex 配置里 `model_instructions_file` 指的那份（替换它的基础提示）：只作比对来源，合并时可选撤掉这个键
    case codexPrompt

    /// 替换基础提示的两份：自己不算"另写一份"，合并时撤不撤由你选（`TidyOrder.retire`）。
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
  /// 文件的绝对路径；正文那一条也按它（`LibraryFileText.path`）
  public let path: String
  /// 正文的哈希（`LibraryEdit.base`）；共读的那份还没有时为 nil
  public let hash: String?
  public let modifiedAt: Date?

  public init(origin: Origin, path: String, hash: String?, modifiedAt: Date?) {
    self.origin = origin
    self.path = path
    self.hash = hash
    self.modifiedAt = modifiedAt
  }
}

/// 几份规则合并成一份：以第一份为底，其余各份里底稿没有的段落（空行隔开，忽略首尾空白）插在它前面那段之后，顺序照原文。
/// 合并稿之后在文件页里改；不猜哪一份对。
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

  /// 按段拆开（空行隔开，去掉首尾空行与空段）：合并与预览按同一种段落认"一样"。
  public static func blocks(of text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: /\n[ \t]*\n/)
      .map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// 一段的比较键：空白不计，只看字。
  public static func normalized(_ block: String) -> String {
    block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
