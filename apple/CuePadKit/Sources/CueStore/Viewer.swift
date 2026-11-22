import Foundation

public struct Viewer: Equatable, Sendable {
  public var device: String
  public var sessionIDs: Set<String>
  public var cue: Bool
  public var modifiedAt: Date
  public var arrivedAt: Date? = nil

  public static func recordID(device: String) -> UUID { DeterministicID.uuid("session-viewer/\(device)") }
}

extension Viewer: Record, SyncedColumns {
  static let table = Table.sessionViewers
  static let fields: [Field] = [.plain("id"), .plain("device"), .plain("sessionIDs"), .plain("modifiedAt"), .plain("cue"), .plain("arrivedAt")]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, JSONColumn.encodeList(sessionIDs.sorted()), modifiedAt, cue, arrivedAt] }
  init(row: Row) {
    self.init(device: row.text(1), sessionIDs: Set(JSONColumn.decodeList(String.self, from: row.textOrNil(2))), cue: row.bool(4), modifiedAt: row.date(3), arrivedAt: row.dateOrNil(5))
  }
}

extension CueStore {
  func watchedOnMac(_ opens: (Viewer) -> Bool) throws -> Bool {
    try viewing().contains { try opens($0) && macOnline($0.device) }
  }

  @discardableResult
  public func recordViewing(device: String, sessionIDs: Set<String>, cue: Bool) throws -> UUID? {
    try write {
      let id = Viewer.recordID(device: device)
      let current = try find(Viewer.self, id)
      guard current.map({ $0.sessionIDs != sessionIDs || $0.cue != cue }) ?? (!sessionIDs.isEmpty || cue) else { return nil }
      try upsert(Viewer(device: device, sessionIDs: sessionIDs, cue: cue, modifiedAt: Date.stamp), updating: ["sessionIDs", "cue", "modifiedAt"])
      return id
    }
  }

  public func arrive(device: String) throws {
    try write {
      let id = Viewer.recordID(device: device)
      let latest = try db.first("SELECT max(arrivedAt) FROM sessionViewers") { $0.dateOrNil(0) }.flatMap(\.self)
      let now = Date.stamp
      let at = latest.map { max(now, $0.addingTimeInterval(0.001)) } ?? now
      let current = try find(Viewer.self, id)
      try upsert(
        Viewer(device: device, sessionIDs: current?.sessionIDs ?? [], cue: current?.cue ?? false, modifiedAt: at, arrivedAt: at),
        updating: ["arrivedAt", "modifiedAt"])
    }
  }

  public func leftFor(device: String) throws -> Bool {
    try db.first(
      """
      SELECT 1 FROM sessionViewers WHERE device != ?1 AND arrivedAt > coalesce((SELECT arrivedAt FROM sessionViewers WHERE device = ?1), -1) LIMIT 1
      """, [device]) { _ in true } ?? false
  }

  private func viewing() throws -> [Viewer] { try select(Viewer.self, where: "json_array_length(sessionIDs) > 0 OR cue", [], orderBy: "id") }
}
