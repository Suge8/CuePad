import Foundation
import CueText

extension Schema {
  /// 72 的那一步（见 `upgrades` 里的说明）。
  static func shownTexts(_ db: SQLite) throws {
    try db.exec("ALTER TABLE deliveryRequests RENAME COLUMN resultDetail TO failure; ALTER TABLE cueMessages ADD COLUMN shownText TEXT; ALTER TABLE piMessages ADD COLUMN shownText TEXT;")
    let failures = try db.query("SELECT id, failure FROM deliveryRequests WHERE failure IS NOT NULL") { ($0.text(0), $0.text(1)) }
    for (id, reason) in failures {
      try db.run("UPDATE deliveryRequests SET failure = ? WHERE id = ?", [ShownText.verbatim(reason).stored, id])
    }
    let reports = try db.query("SELECT id, text FROM cueMessages WHERE author = 'cue' AND taskID IS NOT NULL AND text LIKE '「%'") { ($0.text(0), $0.text(1)) }
    for (id, text) in reports {
      guard let end = text.range(of: "」做完了\n\n") else { continue }
      let task = String(text[text.index(after: text.startIndex)..<end.lowerBound]), evidence = String(text[end.upperBound...])
      try db.run("UPDATE cueMessages SET text = '', shownText = ? WHERE id = ?", [ShownText("「\(task)」做完了\n\n\(evidence)").stored, id])
    }
    let asked = try db.query("SELECT id, ask, places FROM cueMessages WHERE ask LIKE '%/%'") { ($0.text(0), $0.text(1), $0.textOrNil(2)) }
    for (id, ask, stored) in asked {
      guard let project = CueAsked(stored: ask)?.project else { continue }
      var places = JSONColumn.decode([String: CuePlace].self, from: stored) ?? [:]
      places.merge(try CuePlace.capture(task: nil, wake: nil, project: project, in: db)) { old, _ in old }
      try db.run("UPDATE cueMessages SET places = ? WHERE id = ?", [places.isEmpty ? nil : JSONColumn.encode(places), id])
    }
  }
}
