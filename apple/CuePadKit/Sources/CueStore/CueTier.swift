import Foundation

/// 会话交给 Cue 到哪一步：停下时叫不叫醒 Cue、Cue 能替他定什么都只看它。
public enum CueTier: String, CaseIterable, Sendable {
  case yours, push, full

  public static func of(_ session: SessionState, chosen: [String: CueTier]) -> CueTier {
    if let tier = chosen[session.sessionID] { return tier }
    return switch session.turnOpener?.cue {
    case true?: .full
    case false?: .yours
    case nil: session.createdForTaskID == nil ? .yours : .full
    }
  }
}

extension CueStore {
  public func setTier(_ tier: CueTier, of sessionID: String) throws { try mark(.tier(sessionID, tier)) }

  /// 每一档各是一条记录：两台设备各选各的，同步时不会盖掉同一行，以最后选的为准。
  public func chosenTiers() throws -> [String: CueTier] {
    Dictionary(
      try db.query("SELECT subject, kind, MAX(modifiedAt) FROM marks WHERE kind LIKE '\(Mark.tierPrefix)%' GROUP BY subject") { row in
        CueTier(rawValue: String(row.text(1).dropFirst(Mark.tierPrefix.count))).map { (row.text(0), $0) }
      }.compactMap(\.self),
      uniquingKeysWith: { first, _ in first })
  }
}
