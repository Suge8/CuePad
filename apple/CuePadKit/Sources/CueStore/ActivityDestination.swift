import Foundation

/// 一台手机开着的实时活动推送地址：只由这台手机写，Mac 读后经中转发 ActivityKit 推送。
/// 令牌只放在用户自己的 iCloud 加密字段里；没有业务内容、不是第二份 Cue 状态。
/// 每台设备一条，换令牌覆盖、结束删除；未能报结束的最迟按系统的八小时上限失效。
public struct ActivityDestination: Equatable, Sendable {
  public var device: String
  public var activityID: String
  public var token: String
  public var environment: String
  public var startedAt: Date
  public var modifiedAt: Date

  public static let lifetime: TimeInterval = 8 * 60 * 60
  public var expiresAt: Date { startedAt.addingTimeInterval(Self.lifetime) }
  public static func recordID(device: String) -> UUID { DeterministicID.uuid("activity-destination/\(device)") }
}

extension ActivityDestination: Record {
  static let table = Table.activityDestinations
  static let columns = ["id", "device", "activityID", "token", "environment", "startedAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, activityID, token, environment, startedAt, modifiedAt] }
  init(row: Row) {
    self.init(device: row.text(1), activityID: row.text(2), token: row.text(3), environment: row.text(4), startedAt: row.date(5), modifiedAt: row.date(6))
  }
}

extension CueStore {
  /// 优先由 Cue 所在的 Mac 发布；从未选过 Cue 的 Mac 时，用在线设备中标识最小的那台，避免每台都给同一个岛发一份。
  /// 已选的 Mac 离线不换写者：另一台同步来的摘要可能还旧，活动按自己的 stale-date 显示过时。
  public func activityPublisher() throws -> String? {
    if let host = try cueProfile()?.hostID { return host }
    let now = timing.now()
    let online = try select(MacPresence.self, orderBy: "hostID").filter { $0.isOnline(at: now) }
    for presence in online { expire(at: presence.onlineUntil) }
    return online.first?.hostID
  }

  /// 仍在系统最长活动期内的推送地址；到期重读观察，不发过期活动、不需要续期心跳。
  public func activityDestinations() throws -> [ActivityDestination] {
    let now = timing.now()
    return try select(ActivityDestination.self, orderBy: "device").filter {
      guard $0.expiresAt > now else { return false }
      expire(at: $0.expiresAt)
      return true
    }
  }

  @discardableResult
  public func recordActivityDestination(device: String, activityID: String, token: String, environment: String, startedAt: Date) throws -> UUID? {
    try write {
      let id = ActivityDestination.recordID(device: device)
      let old = try find(ActivityDestination.self, id)
      if let old, old.activityID == activityID, old.token == token, old.environment == environment { return nil }
      let began = old.flatMap { $0.activityID == activityID ? $0.startedAt : nil } ?? startedAt
      try upsert(
        ActivityDestination(device: device, activityID: activityID, token: token, environment: environment, startedAt: began, modifiedAt: Date.stamp),
        updating: ["activityID", "token", "environment", "startedAt", "modifiedAt"])
      return id
    }
  }

  /// 旧活动结束的回调不能删掉新活动刚写下的地址。
  @discardableResult
  public func removeActivityDestination(device: String, activityID: String? = nil) throws -> ActivityDestination? {
    try write {
      let id = ActivityDestination.recordID(device: device)
      guard let old = try find(ActivityDestination.self, id), activityID == nil || old.activityID == activityID else { return nil }
      try db.run("DELETE FROM activityDestinations WHERE id = ?", [id])
      return old
    }
  }
}
