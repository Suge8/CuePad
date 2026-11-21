import CueText
import Foundation

public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  public internal(set) var projectID: UUID
  public var body: String
  public var isPinned: Bool
  public var variableValues: [String: String]
  public internal(set) var conflictOf: UUID?
  public internal(set) var sortKey: String
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  public internal(set) var parentID: UUID?
  public internal(set) var todoAt: Date?
  public internal(set) var startedAt: Date?
  public internal(set) var completedAt: Date?
  public internal(set) var piSessionID: String?
  public internal(set) var sessionBindingRevision: SessionBindingRevision?
  public internal(set) var archivedAt: Date?
  public internal(set) var formerSessionIDs: [String] = []

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

public enum CardChange: Sendable, Equatable {
  case trash(id: UUID, lifted: [UUID], schedules: [UUID])
  case archive(id: UUID, at: Date, schedules: [UUID])
  case move(id: UUID, from: CardSlot, after: UUID?)
  case merge(idea: UUID, task: UUID, body: String, modifiedAt: Date)
  case spawn(idea: UUID, task: UUID, modifiedAt: Date)
}

extension Card {
  public var heading: String { CueSummary.title(of: body) }

  public var rest: String? {
    get { CueLines.split(body).rest }
    set { body = CueLines.joined(title: CueLines.split(body).title, rest: newValue) }
  }
}

extension UUID {
  public var shortID: String { String(uuidString.lowercased().prefix(8)) }
}

extension Card: Record, SyncedColumns {
  static let table = Table.cards
  static let fields: [Field] = [
    .plain("id"), .plain("projectID"), .encrypted("body"), .plain("isPinned"), .encrypted("variableValues"), .plain("sortKey"),
    .plain("deletedAt"), .plain("createdAt"), .plain("modifiedAt"), .plain("conflictOf"), .plain("parentID"), .plain("todoAt"),
    .plain("startedAt"), .plain("completedAt"), .plain("piSessionID"), .plain("archivedAt"), .plain("formerSessionIDs"),
    .plain("sessionBindingRevision"),
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
