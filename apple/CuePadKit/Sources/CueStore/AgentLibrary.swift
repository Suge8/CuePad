import CryptoKit
import Foundation

/// 技能与规则：一台 Mac 上各家 Agent 读的技能与规则（AGENTS.md）此刻的样子与该整理的（同步表 `agentLibraries`，每台 Mac 一条、
/// 只由它自己写，同 `MacAgents`；各端只读）。事实源是文件本身（读写规则在 CuePi 的 `AgentLibraryFiles`），这条是那台 Mac 照文件写下的快照，
/// 内容变了才写，`modifiedAt` 是最近一次变的时刻。
/// 快照只有元数据（名字、说明、范围、路径、内容哈希、读不到的几家）；每份文件的正文各是一条（`LibraryFileText`，同步表 `agentLibraryFiles`），
/// 列表上的全局规则预览、文件页、合并稿都读那一条，不另存第二份。
/// 被否决的：正文塞在快照里——几百个技能就超过 iCloud 单条记录 1MB 的上限，超了那条传不上，手机永远停在旧内容；
/// 打开文件页时请 Mac 现读——离线读不到、每次打开一个来回。每文件一条：离线可读、没有来回，改一个技能只传那一条。
/// 手机上的整理与改文件是投送请求（`DeliveryMode.tidy`、`.libraryEdit`），由那台 Mac 照执行时的文件做。
/// 读出时跳过本版本读不懂的条目（更新的版本加的种类），其余照读。
public struct AgentLibrary: Equatable, Sendable {
  public var hostID: String
  /// 那台 Mac 的家目录：路径给人看时缩成 `~`（`shown(_:)`）
  public var home: String
  /// 全局的在前（按分类、名字），各项目的随后（按项目、分类、名字）；同名的各份、格式不对的都在内（`LibrarySkill.problem`）
  public var skills: [LibrarySkill]
  /// 全局规则在前，Pi 的系统提示（有才列）随后，再是这台绑了文件夹的各项目
  public var instructions: [LibraryInstruction]
  /// 该整理的，按 `LibraryTidy.Kind` 的先后；没有问题时为空
  public var tidies: [LibraryTidy]
  /// 各家自管、CuePad 不碰的技能有几个
  public var selfManaged: [SelfManagedSkills]
  /// 这台装着的几家（配置目录在的），按 `AgentKind` 的顺序：读不读得到按它们算（`LibrarySkill.unseenBy`、`unseen(_:)`）；
  /// 与登没登录、能不能开会话（`MacAgents`）无关
  public var agents: [AgentKind]
  public var modifiedAt: Date

  public init(
    hostID: String, home: String, skills: [LibrarySkill], instructions: [LibraryInstruction], tidies: [LibraryTidy],
    selfManaged: [SelfManagedSkills] = [], agents: [AgentKind] = [], modifiedAt: Date
  ) {
    self.hostID = hostID
    self.home = home
    self.skills = skills
    self.instructions = instructions
    self.tidies = tidies
    self.selfManaged = selfManaged
    self.agents = agents
    self.modifiedAt = modifiedAt
  }

  /// 给人看的路径：家目录下的缩成 `~`。
  public func shown(_ path: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  public func instruction(_ kind: LibraryInstruction.Kind) -> LibraryInstruction? { instructions.first { $0.kind == kind } }

  public func skills(in scope: LibraryScope) -> [LibrarySkill] { skills.filter { $0.scope == scope } }

  public func skill(at path: String) -> LibrarySkill? { skills.first { $0.path == path } }

  /// 一份文件在快照里的位置（技能是目录）、正文那一条的路径（`LibraryFileText.path`）与内容哈希（规则还没有文件时为 nil）；快照里没有这一份为 nil。
  public func file(_ file: LibraryFile) -> (path: String, textPath: String, hash: String?)? {
    switch file {
    case .instruction(let kind): instruction(kind).map { ($0.path, $0.path, $0.hash) }
    case .skill(let path): skill(at: path).map { ($0.path, $0.textPath, $0.hash) }
    }
  }

  /// 读不到这份规则的几家（这台装着的、不在 `readers` 里的）；Pi 的系统提示、还没有文件的为空。
  public func unseen(_ instruction: LibraryInstruction) -> [AgentKind] {
    guard instruction.kind != .piSystem, instruction.hash != nil else { return [] }
    return agents.filter { !instruction.readers.contains($0) }
  }

  /// 这个技能所在的同名那件（`LibraryTidy.Kind.duplicate`）。
  public func duplicate(of path: String) -> LibraryTidy? {
    tidies.first { if case .duplicate(_, let copies) = $0.kind { copies.contains { $0.path == path } } else { false } }
  }

  /// 要并进这份规则的那件（`LibraryTidy.merges`）。
  public func merge(into kind: LibraryInstruction.Kind) -> LibraryTidy? { tidies.first { $0.merges && $0.instruction == kind } }

  /// 一键整理做的那几件（不用你选的，`LibraryTidy.isAutomatic`）。
  public var automaticTidies: [LibraryTidy] { tidies.filter(\.isAutomatic) }
  public var automaticOrders: [TidyOrder] { automaticTidies.map { TidyOrder(tidy: $0.id) } }

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

/// 一个技能（有 `SKILL.md` 的目录）：`.agents/skills` 里的，与旧目录里一键整理搬不走的（同名、格式不对的）。
public struct LibrarySkill: Codable, Equatable, Sendable, Identifiable {
  /// 目录名
  public let name: String
  public let scope: LibraryScope
  /// 技能根目录下到它所在目录的分类（"development"、"a/b"）；直接在根下为空（"不在分类里"）
  public let group: String
  /// 技能目录的绝对路径
  public let path: String
  /// frontmatter 里的说明（没有为空串）
  public let description: String
  /// SKILL.md 全文的哈希（`LibraryEdit.base`，读不出的按空串算）：正文在 `LibraryFileText`
  public let hash: String
  public let modifiedAt: Date?
  /// 格式不对的那条（四家最严）；对的为 nil
  public let problem: SkillProblem?
  /// 这台接入了、却读不到它的几家（Claude Code 缺链接；旧目录里的只有那一家读），按 `AgentKind` 的顺序
  public let unseenBy: [AgentKind]

  public var id: String { path }

  /// 正文那一条的路径：它的 SKILL.md。
  public var textPath: String { path + "/SKILL.md" }

  public init(
    name: String, scope: LibraryScope, group: String, path: String, description: String, hash: String, modifiedAt: Date? = nil,
    problem: SkillProblem? = nil, unseenBy: [AgentKind] = []
  ) {
    self.name = name
    self.scope = scope
    self.group = group
    self.path = path
    self.description = description
    self.hash = hash
    self.modifiedAt = modifiedAt
    self.problem = problem
    self.unseenBy = unseenBy
  }
}

/// 技能与规则里的一份文件：文件页打开的、改它的请求指的（`LibraryEdit`）。
public enum LibraryFile: Codable, Hashable, Sendable {
  case instruction(LibraryInstruction.Kind)
  /// 技能目录的绝对路径（写的是它的 SKILL.md）
  case skill(String)
}

/// 一份规则：全局规则（`~/.agents/AGENTS.md`）、Pi 的系统提示（`SYSTEM.md`，存在才列，不跨家统一）、项目规则（`<文件夹>/AGENTS.md`）。
public struct LibraryInstruction: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    case global
    case piSystem
    case project(UUID)
  }

  public let kind: Kind
  /// 文件的绝对路径（还没有时是要写的位置）；正文那一条也按它（`LibraryFileText.path`）
  public let path: String
  /// 正文的哈希（`LibraryEdit.base`）；还没有这个文件为 nil（"还没有 AGENTS.md"）
  public let hash: String?
  public let modifiedAt: Date?
  /// 读这一份的几家（全局规则：各家的全局规则链到它的；项目规则：Claude Code 被同层的另一份 CLAUDE.md 挡住时不在内），按 `AgentKind` 的顺序
  public let readers: [AgentKind]
  /// 链到它的文件（全局：`~/.claude/CLAUDE.md`…；项目：`CLAUDE.md`），绝对路径
  public let links: [String]

  public var id: Kind { kind }

  public init(kind: Kind, path: String, hash: String?, modifiedAt: Date?, readers: [AgentKind] = [], links: [String] = []) {
    self.kind = kind
    self.path = path
    self.hash = hash
    self.modifiedAt = modifiedAt
    self.readers = readers
    self.links = links
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

/// 改一份技能或规则文件（Mac 上文件页的自动存、手机"发往 Mac"的全文，存为 JSON）：`base` 是改之前看到的内容的哈希（`base(of:)`），
/// Mac 上的文件已不是它就不写，退回"Mac 上刚改过"（`AgentLibraryError.changedOnMac`）。
public struct LibraryEdit: Codable, Equatable, Sendable, StoredJSON {
  public var file: LibraryFile
  public var base: String
  public var text: String

  public init(file: LibraryFile, base: String, text: String) {
    self.file = file
    self.base = base
    self.text = text
  }

  /// 内容的哈希（SHA-256 前 16 字节的十六进制）；没有文件为空串。
  public static func base(of text: String?) -> String {
    guard let text else { return "" }
    return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}

/// 整理里的一件（一键整理是不用你选的那几件）：`keep` 只给同名的那件（去重），是留下的那份技能目录；
/// `retire` 只给全局规则的合并，是一并撤掉的替换基础提示的几份（Pi 的进废纸篓、Codex 的撤掉配置键，撤销时都放回）。
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
  /// 改文件时 Mac 上的文件已不是你改之前看到的
  case changedOnMac
  /// 要改的技能已经不在了（移走、改了目录名）
  case gone
  /// 那件已经没了（在别处整理过、文件变了）
  case tidyGone
  /// 规则所在的项目在这台 Mac 上没有绑定的文件夹
  case noFolder
  /// 撤销整理时，整理过的文件之后又改过：整个不撤，不盖掉后来的改动
  case changedSinceTidy

  public var shown: String.LocalizationValue {
    switch self {
    case .changedOnMac: "Mac 上刚改过"
    case .gone: "这份文件已经不在了"
    case .tidyGone: "这件已经不用整理了"
    case .noFolder: "这个项目在这台 Mac 上没有绑定文件夹"
    case .changedSinceTidy: "整理之后这些文件又改过，没有撤销"
    }
  }
}

extension AgentLibrary: Record {
  static let table = Table.agentLibraries
  static let columns = ["id", "hostID", "home", "skills", "instructions", "tidies", "selfManaged", "agents", "modifiedAt"]
  var bindings: [any SQLBindable] {
    [
      Self.recordID(host: hostID), hostID, home, JSONColumn.encodeList(skills), JSONColumn.encodeList(instructions),
      JSONColumn.encodeList(tidies),
      JSONColumn.encodeList(selfManaged), JSONColumn.encodeList(agents.map(\.rawValue)), modifiedAt,
    ]
  }
  init(row: Row) {
    self.init(
      hostID: row.text(1), home: row.text(2),
      skills: JSONColumn.decodeList(Lenient<LibrarySkill>.self, from: row.textOrNil(3)).compactMap(\.value),
      instructions: JSONColumn.decodeList(Lenient<LibraryInstruction>.self, from: row.textOrNil(4)).compactMap(\.value),
      tidies: JSONColumn.decodeList(Lenient<LibraryTidy>.self, from: row.textOrNil(5)).compactMap(\.value),
      selfManaged: JSONColumn.decodeList(Lenient<SelfManagedSkills>.self, from: row.textOrNil(6)).compactMap(\.value),
      agents: JSONColumn.decodeList(String.self, from: row.textOrNil(7)).compactMap(AgentKind.init(rawValue:)),
      modifiedAt: row.date(8))
  }
}

