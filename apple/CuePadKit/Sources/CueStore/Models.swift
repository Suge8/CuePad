import Foundation

public enum Numbering: String, Sendable {
  case none, decimal, alpha, cjk
}

public enum SendTargetKind: String, Sendable {
  case piSession, app, clipboard
}

/// 可观察的表；`CueStore.observe` 按它们订阅变更。
public enum Table: String, Sendable, CaseIterable {
  case projects, cards, tags, cardTags, tasks, sendRecords, attachments, piSessions
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
  /// 绑定的代码目录；Pi 会话按工作目录归入项目。
  public var directory: String?
  public var sortKey: String
  public var isPinned: Bool
  /// 回收站中的项目；其卡片随之进回收站（由项目推导，卡片自身不记）。
  public var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
}

public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// nil 表示未归档（收件箱）。
  public var projectID: UUID?
  /// 纯字符串正文：分块为独占行 `---split---`，图片为 `![](cuepad://img/<哈希>)`。
  public var body: String
  public var numbering: Numbering
  public var isFavorite: Bool
  public var variableValues: [String: String]
  public var sortKey: String
  /// 单独删除进回收站的时间；随项目删除的卡为 nil。
  public var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
}

public struct Tag: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var color: String?
  public var createdAt: Date
  public var modifiedAt: Date
}

/// 卡片与标签的关联；同步记录各有单值 id，所以关联也是独立记录。
struct CardTag: Sendable {
  let id: UUID
  var cardID: UUID
  var tagID: UUID
  var createdAt: Date
  var modifiedAt: Date
}

public struct CueTask: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var projectID: UUID?
  public var sortKey: String
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
  public var targetKind: SendTargetKind
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

/// 仅本机：Pi 会话历史索引与读取偏移。不同步。
public struct PiSession: Identifiable, Equatable, Sendable {
  public let id: String
  public var path: String
  public var cwd: String
  public var title: String
  public var lastActivityAt: Date
  /// 会话文件已解析到的字节偏移。
  public var readOffset: Int

  public init(
    id: String, path: String, cwd: String, title: String = "", lastActivityAt: Date,
    readOffset: Int = 0
  ) {
    self.id = id
    self.path = path
    self.cwd = cwd
    self.title = title
    self.lastActivityAt = lastActivityAt
    self.readOffset = readOffset
  }
}

public struct SendTarget: Sendable {
  public var kind: SendTargetKind
  public var name: String
  public var ref: String?

  public init(kind: SendTargetKind, name: String, ref: String? = nil) {
    self.kind = kind
    self.name = name
    self.ref = ref
  }
}

public struct SearchResults: Sendable {
  public var projects: [Project]
  public var cards: [Card]
}

public enum CueStoreError: Error, Equatable {
  case notFound
  case blankTaskContent
  case blankTagName
}

// MARK: - 行映射

extension Project: Record {
  static let table = Table.projects
  static let columns = ["id", "name", "icon", "color", "directory", "sortKey", "isPinned", "deletedAt", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, name, icon, color, directory, sortKey, isPinned, deletedAt, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), name: row.text(1), icon: row.textOrNil(2), color: row.text(3),
      directory: row.textOrNil(4), sortKey: row.text(5), isPinned: row.bool(6),
      deletedAt: row.dateOrNil(7), createdAt: row.date(8), modifiedAt: row.date(9))
  }
}

extension Card: Record {
  static let table = Table.cards
  static let columns = ["id", "projectID", "body", "numbering", "isFavorite", "variableValues", "sortKey", "deletedAt", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] {
    let variables = try! JSONEncoder.sorted.encode(variableValues)
    return [id, projectID, body, numbering.rawValue, isFavorite, String(decoding: variables, as: UTF8.self), sortKey, deletedAt, createdAt, modifiedAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuidOrNil(1), body: row.text(2),
      numbering: Numbering(rawValue: row.text(3)) ?? .none, isFavorite: row.bool(4),
      variableValues: (try? JSONDecoder().decode([String: String].self, from: Data(row.text(5).utf8))) ?? [:],
      sortKey: row.text(6), deletedAt: row.dateOrNil(7), createdAt: row.date(8), modifiedAt: row.date(9))
  }
}

extension Tag: Record {
  static let table = Table.tags
  static let columns = ["id", "name", "color", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, name, color, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), name: row.text(1), color: row.textOrNil(2), createdAt: row.date(3), modifiedAt: row.date(4))
  }
}

extension CardTag: Record {
  static let table = Table.cardTags
  static let columns = ["id", "cardID", "tagID", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, cardID, tagID, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), cardID: row.uuid(1), tagID: row.uuid(2), createdAt: row.date(3), modifiedAt: row.date(4))
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
      targetKind: SendTargetKind(rawValue: row.text(2)) ?? .app, targetName: row.text(3),
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
  static let columns = ["id", "path", "cwd", "title", "lastActivityAt", "readOffset"]
  var bindings: [any SQLBindable] { [id, path, cwd, title, lastActivityAt, readOffset] }
  init(row: Row) {
    self.init(
      id: row.text(0), path: row.text(1), cwd: row.text(2), title: row.text(3),
      lastActivityAt: row.date(4), readOffset: Int(row.int(5)))
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
  }
}
