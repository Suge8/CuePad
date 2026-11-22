import CueText
import Foundation


public enum CueAuthor: String, Sendable, CaseIterable {
  case you
  case cue
  case note
  case round
}

public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  public var text: String
  public var shownText: ShownText? = nil
  public var shots: [CueShot] = []
  public var urgent: Bool
  public var taskID: UUID?
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  public var tools: ChatMessage.Tools?
  public var answeredRequests: [UUID]? = nil
  public var wake: CueWake? = nil
  public var places: [String: CuePlace] = [:]
  var notify: CuePush?
  public internal(set) var reachedServer = false

  public var alerts: Bool { author == .known(.cue) && urgent }
}

extension CueMessage: Record, SyncedColumns {
  static let table = Table.cueMessages
  static let fields: [Field] = [
    .plain("id"), .plain("author"), .encrypted("text"), .plain("urgent"), .plain("taskID"), .plain("deliveredAt"), .plain("createdAt"),
    .plain("modifiedAt"), .plain("notify"), .encrypted("tools"), .encrypted("askShots"), .plain("wake"), .encrypted("places"),
    .encrypted("shownText"), .plain("answeredRequests"),
  ]
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, shownText == nil ? text : "", urgent, taskID, deliveredAt, createdAt, modifiedAt, notify?.rawValue, tools?.stored,
      JSONColumn.encodeList(shots), wake?.stored, places.isEmpty ? nil : JSONColumn.encode(places), shownText?.stored,
      answeredRequests.map { JSONColumn.encode($0) },
    ]
  }
  init(row: Row) {
    let shown = row.textOrNil(13).flatMap(ShownText.init(stored:))
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: shown?.text ?? row.text(2), shownText: shown,
      shots: JSONColumn.decodeList(CueShot.self, from: row.textOrNil(10)), urgent: row.bool(3), taskID: row.uuidOrNil(4),
      deliveredAt: row.dateOrNil(5), createdAt: row.date(6), modifiedAt: row.date(7), tools: row.textOrNil(9).flatMap(ChatMessage.Tools.init(stored:)),
      answeredRequests: JSONColumn.decode([UUID].self, from: row.textOrNil(14)), wake: row.textOrNil(11).flatMap(CueWake.init(stored:)),
      places: JSONColumn.decode([String: CuePlace].self, from: row.textOrNil(12)) ?? [:], notify: row.textOrNil(8).flatMap(CuePush.init(rawValue:)),
      reachedServer: Self.reachedServer(in: row))
  }
}

package enum CuePush: String, Sendable {
  case alert = "cue"
  case wake = "said"
}

public enum CueReport {
  public static func text(task: String, evidence: [String]) -> ShownText {
    ShownText("「\(task)」做完了\n\n\(evidence.map { "- \($0)" }.joined(separator: "\n"))")
  }
}

public enum CueAlert {
  static let bodyLimit = 300

  public static func content(name: String?, text: String) -> (title: String, body: String) {
    let plain = CueFormat.plainText(text)
    let body = String(AttributedString(inlineMarkdown: plain).characters).trimmingCharacters(in: .whitespacesAndNewlines).clipped(bodyLimit)
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
