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
  public var choices: [String]?
  public var asked: CueAsked?
  public var askAction: String?
  public var askRule: String?
  public var shots: [CueShot] = []
  public var ask: CueAsk? { asked?.ask.known }
  public func allowsFromNowOn(_ answer: String?) -> Bool {
    guard ask != nil, let choices, choices.count > 1 else { return false }
    return answer == choices[1]
  }
  public var asking: CueAsking? { CueAsking(stored: ask, action: askAction, rule: askRule) }
  public var urgent: Bool
  public var taskID: UUID?
  public var answer: String?
  public var answeredAt: Date?
  public var setAsideBy: UUID?
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  public var tools: ChatMessage.Tools?
  public var answeredRequests: [UUID]? = nil
  public var wake: CueWake? = nil
  public var places: [String: CuePlace] = [:]
  var notify: CuePush?
  public internal(set) var reachedServer = false

  public var alerts: Bool { author == .known(.cue) && (choices != nil || urgent) }
}

extension CueMessage: Record, SyncedColumns {
  static let table = Table.cueMessages
  static let fields: [Field] = [
    .plain("id"), .plain("author"), .encrypted("text"), .encrypted("choices"), .plain("urgent"), .plain("taskID"),
    .encrypted("answer"), .plain("answeredAt"), .plain("deliveredAt"), .plain("createdAt"), .plain("modifiedAt"), .plain("notify"),
    .encrypted("tools"), .plain("ask"), .encrypted("askAction"), .encrypted("askRule"), .encrypted("askShots"), .plain("setAsideBy"),
    .plain("wake"), .encrypted("places"), .encrypted("shownText"), .plain("answeredRequests"),
  ]
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, shownText == nil ? text : "", choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify?.rawValue, tools?.stored, asked?.stored, askAction, askRule, JSONColumn.encodeList(shots), setAsideBy, wake?.stored,
      places.isEmpty ? nil : JSONColumn.encode(places), shownText?.stored, answeredRequests.map { JSONColumn.encode($0) },
    ]
  }
  init(row: Row) {
    let shown = row.textOrNil(20).flatMap(ShownText.init(stored:))
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: shown?.text ?? row.text(2), shownText: shown,
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), asked: row.textOrNil(13).flatMap(CueAsked.init(stored:)),
      askAction: row.textOrNil(14), askRule: row.textOrNil(15), shots: JSONColumn.decodeList(CueShot.self, from: row.textOrNil(16)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), setAsideBy: row.uuidOrNil(17), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), tools: row.textOrNil(12).flatMap(ChatMessage.Tools.init(stored:)), answeredRequests: JSONColumn.decode([UUID].self, from: row.textOrNil(21)),
      wake: row.textOrNil(18).flatMap(CueWake.init(stored:)),
      places: JSONColumn.decode([String: CuePlace].self, from: row.textOrNil(19)) ?? [:], notify: row.textOrNil(11).flatMap(CuePush.init(rawValue:)), reachedServer: Self.reachedServer(in: row))
  }
}

package enum CuePush: String, Sendable {
  case alert = "cue"
  case wake = "said"
}

public enum CueQuestionEnd: Equatable, Sendable {
  case answered(String)
  case withdrawn
}

public enum CueReport {
  public static func text(task: String, evidence: [String]) -> ShownText {
    ShownText("「\(task)」做完了\n\n\(evidence.map { "- \($0)" }.joined(separator: "\n"))")
  }
}

public enum CueAlert {
  static let bodyLimit = 300

  public static func content(name: String?, text: String, asking: CueAsking?, choices: [String]?, looks: [String]) -> (title: String, body: String) {
    let body: String
    if let asking, let choices {
      let shots = looks.isEmpty ? [] : [String(localized: "看图：\(looks.joined(separator: String(localized: "；")))")]
      body = ([asking.question] + [asking.why].compactMap(\.self) + shots + [choices.joined(separator: " / ")]).joined(separator: "\n")
    } else {
      let plain = CueFormat.plainText(text)
      body = String(AttributedString(inlineMarkdown: plain).characters).trimmingCharacters(in: .whitespacesAndNewlines).clipped(bodyLimit)
    }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
