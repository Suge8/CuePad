import CryptoKit
import Foundation

/// 技能与说明：一台 Mac 上各家 Agent 读的技能与说明（AGENTS.md）此刻的样子与要整理的（同步表 `agentLibraries`，每台 Mac 一条、
/// 只由它自己写，同 `MacAgents`；各端只读）。事实源是文件本身（读写规则在 CuePi 的 `AgentLibraryFiles`）：CuePad 不存副本，
/// 这条是那台 Mac 照文件写下的快照，内容变了才写（不触发同步），`modifiedAt` 是最近一次变的时刻。
/// 手机上的整理与改说明是投送请求（`DeliveryMode.tidy`、`.instruction`），由那台 Mac 照执行时的文件做。
/// 读出时跳过本版本读不懂的条目（更新的版本加的种类），其余照读。
public struct AgentLibrary: Equatable, Sendable {
  public var hostID: String
  /// 那台 Mac 的家目录：路径给人看时缩成 `~`（`shown(_:)`）
  public var home: String
  /// 全局的在前（按分类、名字），各项目的随后（按项目、分类、名字）
  public var skills: [LibrarySkill]
  /// 全局说明在前，Pi 的系统提示（有才列）随后，再是这台绑了文件夹的各项目
  public var instructions: [LibraryInstruction]
  /// 要整理的，按 `LibraryTidy.Kind` 的先后；没有问题时为空，界面整组不出现
  public var tidies: [LibraryTidy]
  /// 各家自管、CuePad 不碰的技能有几个（接入面板写"不动：…"）
  public var selfManaged: [SelfManagedSkills]
  public var modifiedAt: Date

  public init(
    hostID: String, home: String, skills: [LibrarySkill], instructions: [LibraryInstruction], tidies: [LibraryTidy],
    selfManaged: [SelfManagedSkills] = [], modifiedAt: Date
  ) {
    self.hostID = hostID
    self.home = home
    self.skills = skills
    self.instructions = instructions
    self.tidies = tidies
    self.selfManaged = selfManaged
    self.modifiedAt = modifiedAt
  }

  /// 给人看的路径：家目录下的缩成 `~`。
  public func shown(_ path: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  public func instruction(_ kind: LibraryInstruction.Kind) -> LibraryInstruction? { instructions.first { $0.kind == kind } }

  public func skills(in scope: LibraryScope) -> [LibrarySkill] { skills.filter { $0.scope == scope } }

  /// "全部整理"做的那几件（不要你挑的，`LibraryTidy.isAutomatic`）。
  public var automaticOrders: [TidyOrder] { tidies.filter(\.isAutomatic).map { TidyOrder(tidy: $0.id) } }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("agent-library/\(host)") }

  /// 快照里除写下时刻外的内容：和库里的一样就不写。
  func sameContent(as other: AgentLibrary) -> Bool {
    var other = other
    other.modifiedAt = modifiedAt
    return self == other
  }
}

/// 技能放在哪一层：全局（`~/.agents/skills`）或某个项目（`<绑定的文件夹>/.agents/skills`）。
public enum LibraryScope: Codable, Hashable, Sendable {
  case global
  case project(UUID)
}

/// 一个技能（`<技能目录>/SKILL.md` 读得出、格式对的；格式不对的只进要整理）。
public struct LibrarySkill: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  public let description: String
  public let scope: LibraryScope
  /// 技能根目录下到它所在目录的分类（"development"、"a/b"）；直接在根下为空（"不在分类里"）
  public let group: String
  /// 技能目录的绝对路径
  public let path: String
  /// 这台接入了、却读不到它的几家（Claude Code 缺链接），按 `AgentKind` 的顺序
  public let unseenBy: [AgentKind]

  public var id: String { path }

  public init(name: String, description: String, scope: LibraryScope, group: String, path: String, unseenBy: [AgentKind] = []) {
    self.name = name
    self.description = description
    self.scope = scope
    self.group = group
    self.path = path
    self.unseenBy = unseenBy
  }
}

/// 一份说明：全局说明（`~/.agents/AGENTS.md`）、Pi 的系统提示（`SYSTEM.md`，存在才列，不跨家统一）、项目说明（`<文件夹>/AGENTS.md`）。
public struct LibraryInstruction: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    case global
    case piSystem
    case project(UUID)
  }

  public let kind: Kind
  /// 文件的绝对路径（还没有时是要写的位置）
  public let path: String
  /// 正文；还没有这个文件为 nil（"还没有 AGENTS.md"）
  public let text: String?
  public let modifiedAt: Date?
  /// 读这一份的几家（全局说明：各家的全局说明链到它的；项目说明：Claude Code 被同层的另一份 CLAUDE.md 挡住时不在内），按 `AgentKind` 的顺序
  public let readers: [AgentKind]
  /// 链到它的文件（全局：`~/.claude/CLAUDE.md`…；项目：`CLAUDE.md`），绝对路径
  public let links: [String]

  public var id: Kind { kind }

  public init(kind: Kind, path: String, text: String?, modifiedAt: Date?, readers: [AgentKind] = [], links: [String] = []) {
    self.kind = kind
    self.path = path
    self.text = text
    self.modifiedAt = modifiedAt
    self.readers = readers
    self.links = links
  }

  /// 改它时带的基准（`InstructionEdit.base`）：Mac 上文件此刻的内容与它不同，就是在别处刚改过。
  public var base: String { Self.base(of: text) }

  /// 内容的哈希（SHA-256 前 16 字节的十六进制）；没有文件为空串。
  public static func base(of text: String?) -> String {
    guard let text else { return "" }
    return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}

/// 各家自管、CuePad 不碰的技能（Claude Code 从 claude.ai 同步的 `skills/synced`、Codex 自带的 `skills/.system`）。
public struct SelfManagedSkills: Codable, Equatable, Sendable {
  public let agent: AgentKind
  public let count: Int

  public init(agent: AgentKind, count: Int) {
    self.agent = agent
    self.count = count
  }
}

/// 改一份说明（Mac 上编辑页的自动存、手机"发往 Mac"的正文，存为 JSON）：`base` 是改之前看到的内容的哈希（`LibraryInstruction.base`），
/// Mac 上的文件已不是它就不写，退回"Mac 上刚改过"（`AgentLibraryError.changedOnMac`）。
public struct InstructionEdit: Codable, Equatable, Sendable, StoredJSON {
  public var instruction: LibraryInstruction.Kind
  public var base: String
  public var text: String

  public init(instruction: LibraryInstruction.Kind, base: String, text: String) {
    self.instruction = instruction
    self.base = base
    self.text = text
  }
}

/// 整理里的一件（"全部整理"是全部不要你挑的那几件，不撤替换基础提示的）：`keep` 只给同名的那件，是留下的那份技能目录；
/// `retire` 只给全局说明那件，是合成时一并撤掉的替换基础提示的几份（Pi 的进废纸篓、Codex 的撤掉配置键，撤销时都放回）。
public struct TidyOrder: Codable, Hashable, Sendable {
  public var tidy: String
  public var keep: String?
  public var retire: Set<InstructionSource.Origin>

  public init(tidy: String, keep: String? = nil, retire: Set<InstructionSource.Origin> = []) {
    self.tidy = tidy
    self.keep = keep
    self.retire = retire
  }
}

public enum AgentLibraryError: Error, Equatable, ShownError {
  /// 改说明时 Mac 上的文件已不是你改之前看到的
  case changedOnMac
  /// 要整理的那件已经没了（在别处整理过、文件变了）
  case tidyGone
  /// 说明所在的项目在这台 Mac 上没有绑定的文件夹
  case noFolder
  /// 撤销整理时，整理过的文件之后又改过：整个不撤，不盖掉后来的改动
  case changedSinceTidy

  public var shown: String.LocalizationValue {
    switch self {
    case .changedOnMac: "Mac 上刚改过"
    case .tidyGone: "这件已经不用整理了"
    case .noFolder: "这个项目在这台 Mac 上没有绑定文件夹"
    case .changedSinceTidy: "整理之后这些文件又改过，没有撤销"
    }
  }
}

extension AgentLibrary: Record {
  static let table = Table.agentLibraries
  static let columns = ["id", "hostID", "home", "skills", "instructions", "tidies", "selfManaged", "modifiedAt"]
  var bindings: [any SQLBindable] {
    [
      Self.recordID(host: hostID), hostID, home, JSONColumn.encodeList(skills), JSONColumn.encodeList(instructions), JSONColumn.encodeList(tidies),
      JSONColumn.encodeList(selfManaged), modifiedAt,
    ]
  }
  init(row: Row) {
    self.init(
      hostID: row.text(1), home: row.text(2),
      skills: JSONColumn.decodeList(Lenient<LibrarySkill>.self, from: row.textOrNil(3)).compactMap(\.value),
      instructions: JSONColumn.decodeList(Lenient<LibraryInstruction>.self, from: row.textOrNil(4)).compactMap(\.value),
      tidies: JSONColumn.decodeList(Lenient<LibraryTidy>.self, from: row.textOrNil(5)).compactMap(\.value),
      selfManaged: JSONColumn.decodeList(Lenient<SelfManagedSkills>.self, from: row.textOrNil(6)).compactMap(\.value),
      modifiedAt: row.date(7))
  }
}

extension CueStore {
  /// 这台 Mac 写下自己的技能与说明（`modifiedAt` 不看）；和库里的一样就不写。返回写了的记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordAgentLibrary(_ library: AgentLibrary) throws -> UUID? {
    try write {
      if let stored = try find(AgentLibrary.self, AgentLibrary.recordID(host: library.hostID)), stored.sameContent(as: library) { return nil }
      var record = library
      record.modifiedAt = Date.stamp
      try upsert(record)
      return AgentLibrary.recordID(host: library.hostID)
    }
  }

  /// 要看的那台 Mac 的技能与说明：Mac 上 `host` 给本机；手机上给 nil，看 Cue 运行的那台。那台没写过就是最近写过的一台，一台都没写过为 nil。
  public func agentLibrary(preferring host: String?) throws -> AgentLibrary? {
    if let host = try host ?? cueProfile()?.hostID, let library = try find(AgentLibrary.self, AgentLibrary.recordID(host: host)) { return library }
    return try select(AgentLibrary.self, orderBy: "modifiedAt DESC").first
  }
}
