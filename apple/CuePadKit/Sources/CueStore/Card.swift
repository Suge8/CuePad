import CueText
import Foundation

/// 灵感与任务是同一种记录，差别只是 `todoAt`（建成任务时写上，之后不变：不互转，灵感要做就接进一条任务或照它新建一条，灵感进回收站）。
/// 任务的正文第一行是标题，其余是要交代给 Agent 的话：开工时整段作为第一句发出，发出后留在任务上。
/// 结构（上级、要做、状态）对调用方只读，各有专门的方法。
public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  public internal(set) var projectID: UUID
  public var body: String
  /// 字段名沿用同步记录里的 isPinned。
  public var isPinned: Bool
  public var variableValues: [String: String]
  /// 同一张卡在两台设备上离线并发改了正文时，较旧的版本存成一张新卡，指回原卡。
  public internal(set) var conflictOf: UUID?
  public internal(set) var sortKey: String
  /// 随项目删除的卡为 nil。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 上级不在库里或不可见时按顶层看待。
  public internal(set) var parentID: UUID?
  public internal(set) var todoAt: Date?
  /// 本任务自己的开始事实；明确开工或投送时记下（投送失败不撤回），子任务推进时同事务推进祖先，明确退回待办清空，旧子任务不会在读取时重新启动它。
  public internal(set) var startedAt: Date?
  public internal(set) var completedAt: Date?
  public internal(set) var piSessionID: String?
  public internal(set) var sessionBindingRevision: SessionBindingRevision?
  /// 连同下级一起归档、一起取回。
  public internal(set) var archivedAt: Date?
  /// 叶子以前用过的会话（Pi 自己的会话 id，先换下的在前）：开新会话、改绑、Cue 换新会话时换下来的那个记在这里，
  /// 它仍属于这个叶子（`CueStore.isLoose`）。正在用的只在 `piSessionID`，不在这里。
  public internal(set) var formerSessionIDs: [String] = []

  /// 任务下的灵感不算一级。
  public static let maxTaskDepth = 2

  public var isTask: Bool { todoAt != nil }
  public var isBlank: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  public var status: TaskStatus? {
    guard isTask else { return nil }
    return completedAt != nil ? .done : startedAt != nil ? .inProgress : .todo
  }
}

public enum TaskStatus: String, Sendable, CaseIterable {
  case todo, inProgress, done
}

public struct TaskGroup: Equatable, Sendable {
  public let projectID: UUID
  public internal(set) var tasks: [Card]
}

public struct LeafTask: Identifiable, Equatable, Sendable {
  public let task: Card
  public let parent: Card?
  public var id: UUID { task.id }
}

public struct TaskCounts: Equatable, Sendable {
  public var inProgress: Int
  public var todo: Int
  public var done: Int

  public init(inProgress: Int, todo: Int, done: Int) {
    self.inProgress = inProgress
    self.todo = todo
    self.done = done
  }

  public static let zero = TaskCounts(inProgress: 0, todo: 0, done: 0)

  public var open: Int { inProgress + todo }
}

public struct TaskProgress: Equatable, Sendable {
  public let done: Int
  public let total: Int
  /// 一步都没有时为 nil（直接勾掉、没开过工的子任务量不出用时）。
  public let stepTime: TimeInterval?

  public init(done: Int, total: Int, stepTime: TimeInterval? = nil) {
    self.done = done
    self.total = total
    self.stepTime = stepTime
  }
}

public enum AgentHandoff: Hashable, Sendable {
  case session(String)
  case launching(AgentKind)
}

public enum CardSlot: Hashable, Sendable {
  case top(project: UUID)
  case under(UUID)
}

/// 一次卡片改动的回执：足够原样拨回去的快照，在改动的同一个事务里读到，所以不会和库里的实际写入对不上（`CueStore.undo`）。
public enum CardChange: Sendable, Equatable {
  case trash(id: UUID, lifted: [UUID])
  case move(id: UUID, from: CardSlot, after: UUID?)
  /// 灵感接进任务：任务原来的正文，与接完那一刻任务的修改时刻（撤销时核对，变了就是之后又改过，不撤）。
  case merge(idea: UUID, task: UUID, body: String, modifiedAt: Date)
  /// 新建的那条任务与它此刻的修改时刻（撤销时核对）。
  case spawn(idea: UUID, task: UUID, modifiedAt: Date)
}

extension Card {
  /// Cue 的工具、信封与界面都用这一个标题规则。空白的卡是空串（App 的 `title` 另给占位说法）。
  public var heading: String { CueSummary.title(of: body) }

  /// 写它只换这部分，标题那一行不动。
  public var rest: String? {
    get { CueLines.split(body).rest }
    set { body = CueLines.joined(title: CueLines.split(body).title, rest: newValue) }
  }
}

extension UUID {
  /// Cue 的工具接受至少 4 位的前缀。
  public var shortID: String { String(uuidString.lowercased().prefix(8)) }
}

extension Card: Record {
  static let table = Table.cards
  static let columns = [
    "id", "projectID", "body", "isPinned", "variableValues", "sortKey", "deletedAt", "createdAt", "modifiedAt", "conflictOf",
    "parentID", "todoAt", "startedAt", "completedAt", "piSessionID", "archivedAt", "formerSessionIDs", "sessionBindingRevision",
  ]
  static var selection: String { selection(as: "cards") }

  static func selection(as alias: String) -> String {
    columns.map { "\(alias).\($0)" }.joined(separator: ", ")
  }

  var bindings: [any SQLBindable] {
    [
      id, projectID, body, isPinned, JSONColumn.encode(variableValues), sortKey, deletedAt, createdAt, modifiedAt, conflictOf,
      parentID, todoAt, startedAt, completedAt, piSessionID, archivedAt, JSONColumn.encodeList(formerSessionIDs), sessionBindingRevision?.stored,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), body: row.text(2), isPinned: row.bool(3),
      variableValues: Self.variables(row.text(4)),
      conflictOf: row.uuidOrNil(9), sortKey: row.text(5), deletedAt: row.dateOrNil(6), createdAt: row.date(7), modifiedAt: row.date(8),
      parentID: row.uuidOrNil(10), todoAt: row.dateOrNil(11), startedAt: row.dateOrNil(12),
      completedAt: row.dateOrNil(13), piSessionID: row.textOrNil(14), sessionBindingRevision: row.textOrNil(17).flatMap(SessionBindingRevision.init(stored:)), archivedAt: row.dateOrNil(15),
      formerSessionIDs: JSONColumn.decodeList(String.self, from: row.textOrNil(16)))
  }

  /// 几乎所有卡片没有变量取值（存成 "{}"），不为它们创建解码器。
  private static func variables(_ stored: String) -> [String: String] {
    stored == "{}" ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
  }
}

public struct CardConflict: Equatable, Sendable {
  public var original: Card
  public var copy: Card
}

public enum ConflictChoice: Sendable {
  case original
  case copy
}
