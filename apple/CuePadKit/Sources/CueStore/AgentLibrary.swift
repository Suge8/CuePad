import CryptoKit
import Foundation

/// 每台 Mac 一条、只由它自己写。事实源是文件本身，这条是那台 Mac 照文件写下的快照，内容变了才写。
/// 快照只有元数据；每份文件的正文各是一条（`LibraryFileText`），列表预览、文件页、合并稿都读那一条，不另存第二份。
/// 被否决的：正文塞在快照里——几百个技能就超过 iCloud 单条记录 1MB 的上限，超了那条传不上，手机永远停在旧内容；打开文件页时请 Mac 现读——离线读不到、每次打开一个来回。
/// 读出时跳过本版本读不懂的条目（更新的版本加的种类），其余照读。
public struct AgentLibrary: Equatable, Sendable {
  public var hostID: String
  public var home: String
  public var skills: [LibrarySkill]
  public var instructions: [LibraryInstruction]
  public var tidies: [LibraryTidy]
  public var selfManaged: [SelfManagedSkills]
  /// 这台装着的几家（配置目录在的）：与登没登录、能不能开会话（`MacAgents`）无关。
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

  public func shown(_ path: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  public func instruction(_ kind: LibraryInstruction.Kind) -> LibraryInstruction? { instructions.first { $0.kind == kind } }

  public func skills(in scope: LibraryScope) -> [LibrarySkill] { skills.filter { $0.scope == scope } }

  public func skill(at path: String) -> LibrarySkill? { skills.first { $0.path == path } }

  public func file(_ file: LibraryFile) -> (textPath: String, hash: String?)? {
    switch file {
    case .instruction(let kind): instruction(kind).map { ($0.path, $0.hash) }
    case .skill(let path): skill(at: path).map { ($0.textPath, $0.hash) }
    }
  }

  public func unseen(_ instruction: LibraryInstruction) -> [AgentKind] {
    guard instruction.kind != .piSystem, instruction.hash != nil else { return [] }
    return agents.filter { !instruction.readers.contains($0) }
  }

  public func duplicate(of path: String) -> LibraryTidy? {
    tidies.first { if case .duplicate(_, let copies) = $0.kind { copies.contains { $0.path == path } } else { false } }
  }

  public func merge(into kind: LibraryInstruction.Kind) -> LibraryTidy? { tidies.first { $0.merges && $0.instruction == kind } }

  public var automaticTidies: [LibraryTidy] { tidies.filter(\.isAutomatic) }
  public var automaticOrders: [TidyOrder] { automaticTidies.map { TidyOrder(tidy: $0.id) } }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("agent-library/\(host)") }

  func sameContent(as other: AgentLibrary) -> Bool {
    var other = other
    other.modifiedAt = modifiedAt
    return self == other
  }
}

public enum LibraryScope: Codable, Hashable, Sendable {
  case global
  case project(UUID)
}

public struct LibrarySkill: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  public let scope: LibraryScope
  public let group: String
  public let path: String
  public let description: String
  public let hash: String
  public let modifiedAt: Date?
  public let problem: SkillProblem?
  public let unseenBy: [AgentKind]

  public var id: String { path }

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

public enum LibraryFile: Codable, Hashable, Sendable {
  case instruction(LibraryInstruction.Kind)
  case skill(String)
}

public struct LibraryInstruction: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    case global
    case piSystem
    case project(UUID)
  }

  public let kind: Kind
  public let path: String
  public let hash: String?
  public let modifiedAt: Date?
  /// 项目规则里 Claude Code 被同层的另一份 CLAUDE.md 挡住时不在内。
  public let readers: [AgentKind]
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

public struct SelfManagedSkills: Codable, Equatable, Sendable {
  public let agent: AgentKind
  public let count: Int

  public init(agent: AgentKind, count: Int) {
    self.agent = agent
    self.count = count
  }
}

/// Mac 上的文件已不是 `base` 就不写，退回“Mac 上刚改过”（`AgentLibraryError.changedOnMac`）。
public struct LibraryEdit: Codable, Equatable, Sendable, StoredJSON {
  public var file: LibraryFile
  public var base: String
  public var text: String

  public init(file: LibraryFile, base: String, text: String) {
    self.file = file
    self.base = base
    self.text = text
  }

  /// 没有文件与空文件都是空串：文件页把“还没有”当空文本，哈希要与 Mac 上的对得上。
  public static func base(of text: String?) -> String {
    guard let text, !text.isEmpty else { return "" }
    return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}

/// 整理里的一件（一键整理是不用你选的那几件）：`keep` 只给同名的那件（去重），是留下的那份技能目录；
/// `retire` 只给全局规则的合并，是一并撤掉的替换基础提示的几份（Pi 的进废纸篓、Codex 的撤掉配置键，撤销时都放回）；
/// `base` 只给合并，是你看过的合并稿出自的那一版（`LibraryTidy.base`），Mac 上的文件已不是它就不合并、退回"Mac 上刚改过"。
public struct TidyOrder: Codable, Hashable, Sendable {
  public var tidy: String
  public var keep: String?
  public var retire: Set<InstructionSource.Origin>
  public var base: String?

  public init(tidy: String, keep: String? = nil, retire: Set<InstructionSource.Origin> = [], base: String? = nil) {
    self.tidy = tidy
    self.keep = keep
    self.retire = retire
    self.base = base
  }
}

public enum AgentLibraryError: Error, Equatable, ShownError {
  case changedOnMac
  case gone
  case tidyGone
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

