import Foundation

/// 唯一的内容记录。界面上叫灵感或任务：同一种记录，差别只是 `todoAt`（"设为任务"时写上，"改回灵感"时清掉）。
/// 灵感没有状态；任务有三态（由开始与完成两个时间推出）、可有下级——步骤（顶层任务下的任务，勾选清单里的一条）与当资料的灵感。
/// 任务的正文第一行是标题，其余是要交代给 Agent 的话（`CueLines.split`）：开工时整段作为第一句发出，发出后留在任务上。
/// 结构（上级、要做、状态）对调用方只读，各有专门的方法：`setTodo`、`setStatus`、`moveCard`、`createTask`。
public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 所在的项目；没指定的在默认项目（`Project.defaultID`）。
  public internal(set) var projectID: UUID
  /// 正文：一段 Markdown（`CueFormat`），图片为 `![](cuepad://img/<哈希>)`。
  public var body: String
  /// 资料：项目里长期参考的灵感（项目页任务区下面一组）。字段名沿用同步记录里的 isPinned。
  public var isPinned: Bool
  public var variableValues: [String: String]
  /// 冲突副本指向的原卡：同一张卡在两台设备上离线并发改了正文时，较旧的版本存成一张新卡，指回原卡，
  /// 由用户用 `resolveConflict` 选择保留哪一个。普通卡为 nil。
  public internal(set) var conflictOf: UUID?
  public internal(set) var sortKey: String
  /// 单独删除进回收站的时间；随项目删除的卡为 nil。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 上级任务；nil 是顶层。只有任务能当上级，任务最多 `maxTaskDepth` 级；上级不在库里或不可见时按顶层看待。
  public internal(set) var parentID: UUID?
  /// "设为任务"的时间：有值是任务，nil 是灵感。
  public internal(set) var todoAt: Date?
  /// 自己记下的开始时间（手动置为进行中、或发给 Agent 时；列 `startedAt`）；回到待办时清空。
  var ownStartedAt: Date?
  /// 开始的时间：自己记下的，没有时是步骤里最早开始（没开始就做完的算做完那一刻）的时刻——有步骤的任务从步骤推出，
  /// 不另存（读出时由 `Card.startedSQL` 算，计数、正在推进与排序同一条 SQL）。
  public internal(set) var startedAt: Date?
  public internal(set) var completedAt: Date?
  /// 发给 Agent 的会话（Pi 自己的会话 id），灵感与任务的行据此显示会话此刻的状态。
  public internal(set) var piSessionID: String?
  /// 归档的时刻：做完或不再需要，留着可搜、不占列表；连同下级一起归档、一起取回（`archive` / `unarchive`）。
  public internal(set) var archivedAt: Date?
  /// 叶子以前用过的会话（Pi 自己的会话 id，先换下的在前）：开新会话、改绑、Cue 换新会话时换下来的那个记在这里，
  /// 它仍属于这个叶子（`CueStore.isLoose`）。正在用的只在 `piSessionID`，不在这里。
  public internal(set) var formerSessionIDs: [String] = []

  /// 任务最多两级：任务 → 步骤。任务下的灵感不算一级。
  public static let maxTaskDepth = 2

  public var isTask: Bool { todoAt != nil }
  /// 空白：正文只有空白（没有文字也没有图片）。空白灵感离开编辑就不留下（`CueStore.dropIfBlank`），也不计数、不当摘要。
  public var isBlank: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// 任务的三态（`TaskStatus`）；灵感为 nil。
  public var status: TaskStatus? {
    guard isTask else { return nil }
    return completedAt != nil ? .done : startedAt != nil ? .inProgress : .todo
  }
}

/// 任务三态。由两个时间推出（唯一事实源）：有完成时间是完成，否则开始过（`Card.startedAt`：自己的，或任一步骤开始过、做完过）是进行中，
/// 都没有是待办。有步骤的任务不用另记开始：步骤一开工它就是进行中。
public enum TaskStatus: String, Sendable, CaseIterable {
  case todo, inProgress, done
}

/// 同一项目里某一状态的任务（`CueStore.tasks(_:)`）。
public struct TaskGroup: Equatable, Sendable {
  public let projectID: UUID
  public internal(set) var tasks: [Card]
}

/// 叶子任务，步骤带着它的上级（能绑会话的 `CueStore.bindableTasks`、绑着会话的 `CueStore.tasks(boundTo:)`）：界面写"上级 · 步骤"。
public struct LeafTask: Identifiable, Equatable, Sendable {
  public let task: Card
  /// 步骤的上级任务；顶层任务为 nil。
  public let parent: Card?
  public var id: UUID { task.id }
}

/// 一组顶层任务按状态的个数（`CueStore.taskCounts`）：给用户看的任务数与完成数都是它。
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

  public static func + (lhs: TaskCounts, rhs: TaskCounts) -> TaskCounts {
    TaskCounts(inProgress: lhs.inProgress + rhs.inProgress, todo: lhs.todo + rhs.todo, done: lhs.done + rhs.done)
  }
}

/// 步骤完成了几个、一共几个（任务的直接步骤，见 `CueStore.subtaskProgress`），与做完的步骤平均每步用了多久（任务行估还要多久，`TaskPace`）。
public struct TaskProgress: Equatable, Sendable {
  public let done: Int
  public let total: Int
  /// 做完的步骤里记着自己开始时刻的，从开始到做完的平均秒数；一步都没有时为 nil（直接勾掉、没开过工的步骤量不出用时）。
  public let stepTime: TimeInterval?

  public init(done: Int, total: Int, stepTime: TimeInterval? = nil) {
    self.done = done
    self.total = total
    self.stepTime = stepTime
  }
}

/// 灵感或任务交给了 Agent 的哪里：一个会话（Pi 会话 id），或正在开的新会话（还没开好、没认领到）。见 `CueStore.handedSessions`。
public enum AgentHandoff: Hashable, Sendable {
  case session(String)
  case launching
}

/// 卡片挂在哪：某项目的顶层，或某条任务下面（项目随它）。
public enum CardSlot: Hashable, Sendable {
  case top(project: UUID)
  case under(UUID)
}

/// 一次卡片改动的回执：足够原样拨回去的快照，在改动的同一个事务里读到，所以不会和库里的实际写入对不上（`CueStore.undo`）。
public enum CardChange: Sendable, Equatable {
  /// 设为任务（`on`）或改回灵感：提上去的下级。
  case todo(id: UUID, on: Bool, lifted: [UUID])
  /// 删除：提上去的下级。
  case trash(id: UUID, lifted: [UUID])
  /// 挪动：原来的位置与原来的前一个同级。
  case move(id: UUID, from: CardSlot, after: UUID?)
}

extension Card: Record {
  static let table = Table.cards
  static let columns = [
    "id", "projectID", "body", "isPinned", "variableValues", "sortKey", "deletedAt", "createdAt", "modifiedAt", "conflictOf",
    "parentID", "todoAt", "startedAt", "completedAt", "piSessionID", "archivedAt", "formerSessionIDs",
  ]
  static var selection: String { selection(as: "cards") }

  /// 读卡片的列：存着的列加上推出来的开始时间（`startedSQL`），`init(row:)` 按这个顺序读。
  static func selection(as alias: String) -> String {
    (columns.map { "\(alias).\($0)" } + [startedSQL(alias)]).joined(separator: ", ")
  }

  /// 表 `alias` 里任务的开始时间（`Card.startedAt`）：自己记下的，没有时取步骤（没删除的下级任务）里最早的开始或做完时刻；灵感为 NULL。
  /// 开始过就是进行中只在这里定义：卡片读出、顶层计数、正在推进的筛选与排序都用它。
  static func startedSQL(_ alias: String) -> String {
    """
    CASE WHEN \(alias).todoAt IS NOT NULL THEN COALESCE(\(alias).startedAt, (SELECT MIN(COALESCE(s.startedAt, s.completedAt)) FROM cards s
      WHERE s.parentID = \(alias).id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL)) END
    """
  }

  var bindings: [any SQLBindable] {
    [
      id, projectID, body, isPinned, JSONColumn.encode(variableValues), sortKey, deletedAt, createdAt, modifiedAt, conflictOf,
      parentID, todoAt, ownStartedAt, completedAt, piSessionID, archivedAt, JSONColumn.encodeList(formerSessionIDs),
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), body: row.text(2), isPinned: row.bool(3),
      variableValues: Self.variables(row.text(4)),
      conflictOf: row.uuidOrNil(9), sortKey: row.text(5), deletedAt: row.dateOrNil(6), createdAt: row.date(7), modifiedAt: row.date(8),
      parentID: row.uuidOrNil(10), todoAt: row.dateOrNil(11), ownStartedAt: row.dateOrNil(12), startedAt: row.dateOrNil(17),
      completedAt: row.dateOrNil(13), piSessionID: row.textOrNil(14), archivedAt: row.dateOrNil(15),
      formerSessionIDs: JSONColumn.decodeList(String.self, from: row.textOrNil(16)))
  }

  /// 几乎所有卡片没有变量取值（存成 "{}"），不为它们创建解码器。
  private static func variables(_ stored: String) -> [String: String] {
    stored == "{}" ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
  }
}

/// 一张卡的冲突：原卡（较新的版本）与冲突副本（较旧的正文）。
public struct CardConflict: Equatable, Sendable {
  public var original: Card
  public var copy: Card
}

public enum ConflictChoice: Sendable {
  /// 保留原卡的正文，删除副本。
  case original
  /// 用副本的正文替换原卡的正文，删除副本。
  case copy
}
