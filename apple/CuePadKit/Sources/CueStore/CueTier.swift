import Foundation

/// 会话交给 Cue 到哪一步：停下时叫不叫醒 Cue、Cue 能替他定什么都只看它。
public enum CueTier: String, CaseIterable, Comparable, Sendable {
  case yours, push, full

  public static func < (a: CueTier, b: CueTier) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

  public static func of(_ session: SessionState, chosen: [String: CueTier]) -> CueTier { chosen[session.sessionID] ?? .yours }
}

extension CueStore {
  /// 记的时刻晚于这个会话已有的每一档：时钟慢的设备看到别处的选择之后再选，也算后选。
  public func setTier(_ tier: CueTier, of sessionID: String) throws {
    try write {
      let latest = try db.first("SELECT MAX(modifiedAt) FROM marks WHERE kind LIKE '\(Mark.tierPrefix)%' AND subject = ?", [sessionID]) { $0.dateOrNil(0) } ?? nil
      try putMark(.tier(sessionID, tier), at: max(.stamp, (latest ?? .distantPast).addingTimeInterval(0.001)))
    }
  }

  /// 每一档各是一条记录：两台设备各选各的，同步时不会盖掉同一行，以最后选的为准；同一刻选的取交出去少的那档。
  public func chosenTiers() throws -> [String: CueTier] {
    var chosen: [String: (at: Int64, tier: CueTier)] = [:]
    for row in try db.query("SELECT subject, kind, modifiedAt FROM marks WHERE kind LIKE '\(Mark.tierPrefix)%'", [], { ($0.text(0), $0.text(1), $0.int(2)) }) {
      guard let tier = CueTier(rawValue: String(row.1.dropFirst(Mark.tierPrefix.count))) else { continue }
      if let kept = chosen[row.0], kept.at > row.2 || (kept.at == row.2 && kept.tier < tier) { continue }
      chosen[row.0] = (row.2, tier)
    }
    return chosen.mapValues(\.tier)
  }
}
