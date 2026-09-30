import CueText
import Foundation

/// 发送目标种类。
public enum SendTargetKind: String, Sendable, CaseIterable {
  case piSession, app, clipboard
}

/// 可观察的表；`CueStore.observe` 按它们订阅变更。
public enum Table: String, Sendable, CaseIterable {
  case projects, cards, tasks, sendRecords, attachments, piSessions, projectDirectories
  case piSessionStates, deliveryRequests
}

extension Table {
  /// 进入 iCloud 同步的表；其余是本机表。
  package static let synced: [Table] = [
    .projects, .cards, .tasks, .sendRecords, .attachments, .piSessionStates, .deliveryRequests,
  ]

  /// 同步的列（CKRecord 的字段）；不含本机列。
  package var columns: [String] {
    switch self {
    case .projects: Project.columns
    case .cards: Card.columns
    case .tasks: CueTask.columns
    case .sendRecords: SendRecord.columns
    case .attachments: Attachment.columns
    case .piSessions: PiSession.columns
    case .projectDirectories: ["projectID", "directory"]
    case .piSessionStates: PiSessionState.columns
    case .deliveryRequests: DeliveryRequest.syncedColumns
    }
  }
}

/// 表行与列的对应。`bindings[0]` 是主键；`columns` 与 `bindings`、`init(row:)` 的读取序号一致。
protocol Record: Sendable {
  static var table: Table { get }
  static var columns: [String] { get }
  var bindings: [any SQLBindable] { get }
  init(row: Row)
}

public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var icon: String?
  public var color: String
  public internal(set) var sortKey: String
  public var isPinned: Bool
  /// 项目目标卡；必须是本项目里未删除的卡。用 `setGoal` 设置，卡片离开项目或进回收站时自动清空。
  public internal(set) var goalCardID: UUID?
  /// 回收站中的项目；其卡片随之进回收站（由项目推导，卡片自身不记）。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
}

public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// nil 表示未归档（收件箱）。
  public internal(set) var projectID: UUID?
  /// 纯字符串正文：分块为独占行 `---split---`，图片为 `![](cuepad://img/<哈希>)`。
  public var body: String
  public var numbering: Open<CueNumbering>
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
}

public struct CueTask: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var projectID: UUID?
  public internal(set) var sortKey: String
  public var completedAt: Date?
  /// 关联的 Pi 会话（Pi 自己的会话 id）。
  public var piSessionID: String?
  public var createdAt: Date
  public var modifiedAt: Date
}

public struct SendRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 发送时的内容快照；卡片之后改动或删除都不影响。
  public var content: String
  public var targetKind: Open<SendTargetKind>
  public var targetName: String
  /// Pi 会话 id 或应用 bundle id。
  public var targetRef: String?
  public var cardID: UUID?
  public var taskID: UUID?
  public var sentAt: Date
  public var modifiedAt: Date
}

/// 图片附件元数据；文件按内容哈希存在磁盘，缩略图是派生缓存不入库。
public struct Attachment: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hash: String
  public var byteCount: Int
  public var format: String
  public var createdAt: Date
  public var modifiedAt: Date
}

/// 仅本机：Pi 会话历史索引的元数据。检查点（含读取偏移）另存，用 `piCheckpoint(of:)` 读取。不同步。
public struct PiSession: Identifiable, Equatable, Sendable {
  public let id: String
  public var path: String
  public var cwd: String
  public var title: String
  public var lastActivityAt: Date

  public init(id: String, path: String, cwd: String, title: String = "", lastActivityAt: Date) {
    self.id = id
    self.path = path
    self.cwd = cwd
    self.title = title
    self.lastActivityAt = lastActivityAt
  }
}

public struct SendTarget: Equatable, Sendable {
  public var kind: Open<SendTargetKind>
  public var name: String
  public var ref: String?

  public init(kind: Open<SendTargetKind>, name: String, ref: String? = nil) {
    self.kind = kind
    self.name = name
    self.ref = ref
  }

  public init(kind: SendTargetKind, name: String, ref: String? = nil) {
    self.init(kind: .known(kind), name: name, ref: ref)
  }
}

/// 卡片搜索条件。所有条件同时满足；筛选在分页之前生效。
/// 没有关键词、没有任何筛选时列出该范围内的全部卡片（按最近修改）。
public struct SearchQuery: Sendable, ExpressibleByStringLiteral {
  /// 按空白拆成多个词，每个词都要命中（子串，大小写不敏感）。卡片按正文命中；项目名只用于单列的项目结果。
  /// 空表示不按文字过滤。
  public var text: String
  /// 限定所属项目；nil 元素表示未归档；nil 表示不限；空集合无结果。
  public var projects: Set<UUID?>?
  /// true 只要含图片的卡，false 只要不含图片的卡，nil 不限。
  public var hasImages: Bool?
  /// 发送条件：不限、从未发送过、或发送过（可限目标）。
  public var sent: SendCondition
  /// 卡片最近修改时间落在区间内（含两端）。
  public var modifiedIn: ClosedRange<Date>?
  /// true 只搜回收站里的内容（含随项目进回收站的卡片），false 只搜未删除内容。
  public var inTrash: Bool

  public init(
    text: String = "", projects: Set<UUID?>? = nil, hasImages: Bool? = nil, sent: SendCondition = .any,
    modifiedIn: ClosedRange<Date>? = nil, inTrash: Bool = false
  ) {
    self.text = text
    self.projects = projects
    self.hasImages = hasImages
    self.sent = sent
    self.modifiedIn = modifiedIn
    self.inTrash = inTrash
  }

  public init(stringLiteral value: String) { self.init(text: value) }

  var hasCardFilters: Bool { projects != nil || hasImages != nil || sent != .any || modifiedIn != nil }
}

/// 搜索的发送条件。
public enum SendCondition: Equatable, Sendable {
  /// 不限。
  case any
  /// 从未发送过（没有任何关联该卡的发送记录）。
  case never
  /// 至少发送过一次；可限目标种类与名称（名称精确匹配），都省略表示发到哪里都行。
  case sent(kind: Open<SendTargetKind>? = nil, name: String? = nil)
}

/// 一张卡最近一次发送：何时、发给谁。
public struct LastSend: Equatable, Sendable {
  public var sentAt: Date
  public var target: SendTarget

  public init(sentAt: Date, target: SendTarget) {
    self.sentAt = sentAt
    self.target = target
  }
}

public struct SearchResults: Sendable {
  /// 项目名命中的项目；只在有关键词、没有卡片筛选、第一页时返回。
  public var projects: [Project]
  /// 当前页的卡片，按最近修改。
  public var cards: [Card]
  /// 符合条件的卡片总数（不受分页影响）。
  public var totalCards: Int
}

/// 侧栏用：项目（nil = 未归档）的可见卡片数与最近修改时间；没有卡片时 `lastModifiedAt` 为 nil。
public struct ProjectSummary: Equatable, Sendable {
  public var projectID: UUID?
  public var cardCount: Int
  public var lastModifiedAt: Date?
}

public enum CueStoreError: Error, Equatable {
  case notFound
  case blankTaskContent
  case notAnImage
  /// 目标卡必须是该项目里未删除的卡。
  case invalidGoal
  /// 卡片或任务只能归属存在且未在回收站的项目（或不归属任何项目）。
  case invalidProject
  /// `resolveConflict` 的目标不是冲突副本。
  case notAConflictCopy
  /// 下载的附件内容与其哈希不符。
  case attachmentHashMismatch
  case blankDeliveryContent
  /// 永久删除已完成，但这些哈希的图片文件没能删掉（记录与文件保留）。
  case attachmentFilesNotRemoved([String])
  /// 库文件的结构版本不是本版本建的（开发期旧结构或更新版本的库），不打开。
  case unsupportedSchemaVersion(Int)
}

extension CueStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notFound: "找不到这条记录，可能已被删除"
    case .blankTaskContent: "任务内容不能为空"
    case .notAnImage: "不是可识别的图片"
    case .invalidGoal: "目标卡必须是这个项目里未删除的卡片"
    case .invalidProject: "目标项目已不存在或在回收站"
    case .notAConflictCopy: "这张卡片不是冲突副本"
    case .attachmentHashMismatch: "附件内容与其哈希不符"
    case .blankDeliveryContent: "发送内容不能为空"
    case .attachmentFilesNotRemoved(let hashes): "已永久删除，但有 \(hashes.count) 个图片文件没能删掉"
    case .unsupportedSchemaVersion(let version): "资料库由另一个版本的 CuePad 建立（结构版本 \(version)），这个版本打不开"
    }
  }
}

// MARK: - 行映射

extension Project: Record {
  static let table = Table.projects
  static let columns = ["id", "name", "icon", "color", "sortKey", "isPinned", "deletedAt", "createdAt", "modifiedAt", "goalCardID"]
  var bindings: [any SQLBindable] { [id, name, icon, color, sortKey, isPinned, deletedAt, createdAt, modifiedAt, goalCardID] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), name: row.text(1), icon: row.textOrNil(2), color: row.text(3),
      sortKey: row.text(4), isPinned: row.bool(5), goalCardID: row.uuidOrNil(9),
      deletedAt: row.dateOrNil(6), createdAt: row.date(7), modifiedAt: row.date(8))
  }
}

extension Card: Record {
  static let table = Table.cards
  static let columns = ["id", "projectID", "body", "numbering", "isPinned", "variableValues", "sortKey", "deletedAt", "createdAt", "modifiedAt", "conflictOf"]
  var bindings: [any SQLBindable] {
    let variables = try! JSONEncoder.sorted.encode(variableValues)
    return [id, projectID, body, numbering.rawValue, isPinned, String(decoding: variables, as: UTF8.self), sortKey, deletedAt, createdAt, modifiedAt, conflictOf]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuidOrNil(1), body: row.text(2),
      numbering: Open(rawValue: row.text(3)), isPinned: row.bool(4),
      variableValues: (try? JSONDecoder().decode([String: String].self, from: Data(row.text(5).utf8))) ?? [:],
      conflictOf: row.uuidOrNil(10), sortKey: row.text(6), deletedAt: row.dateOrNil(7), createdAt: row.date(8), modifiedAt: row.date(9))
  }
}

extension CueTask: Record {
  static let table = Table.tasks
  static let columns = ["id", "content", "projectID", "sortKey", "completedAt", "piSessionID", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, content, projectID, sortKey, completedAt, piSessionID, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1), projectID: row.uuidOrNil(2), sortKey: row.text(3),
      completedAt: row.dateOrNil(4), piSessionID: row.textOrNil(5), createdAt: row.date(6),
      modifiedAt: row.date(7))
  }
}

extension SendRecord: Record {
  static let table = Table.sendRecords
  static let columns = ["id", "content", "targetKind", "targetName", "targetRef", "cardID", "taskID", "sentAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, content, targetKind.rawValue, targetName, targetRef, cardID, taskID, sentAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      targetKind: Open(rawValue: row.text(2)), targetName: row.text(3),
      targetRef: row.textOrNil(4), cardID: row.uuidOrNil(5), taskID: row.uuidOrNil(6),
      sentAt: row.date(7), modifiedAt: row.date(8))
  }
}

extension Attachment: Record {
  static let table = Table.attachments
  static let columns = ["id", "hash", "byteCount", "format", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hash, byteCount, format, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), hash: row.text(1), byteCount: Int(row.int(2)), format: row.text(3), createdAt: row.date(4), modifiedAt: row.date(5))
  }
}

extension PiSession: Record {
  static let table = Table.piSessions
  static let columns = ["id", "path", "cwd", "title", "lastActivityAt"]
  var bindings: [any SQLBindable] { [id, path, cwd, title, lastActivityAt] }
  init(row: Row) {
    self.init(
      id: row.text(0), path: row.text(1), cwd: row.text(2), title: row.text(3),
      lastActivityAt: row.date(4))
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
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
