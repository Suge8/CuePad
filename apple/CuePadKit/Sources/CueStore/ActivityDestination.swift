import Foundation

/// 一台手机的实时活动推送地址：只由这台手机写，Mac 读后经中转发 ActivityKit 推送。
/// 一台手机至多两行：开着的那只活动的（内容与结束推给它，活动没了就删），和远程开一只新活动用的（`isStarter`，一直留着）。
/// 后者放同一张表、activityID 为空、startedAt 写 0：还没更新的 Mac 把它当过期地址略过，不用另加同步表。
/// 令牌只放在用户自己的 iCloud 加密字段里；没有业务内容、不是第二份 Cue 状态。
/// 未能报结束的最迟按系统的八小时上限失效。
public struct ActivityDestination: Equatable, Sendable {
  public var device: String
  public var activityID: String
  public var token: String
  public var environment: String
  public var startedAt: Date
  public var modifiedAt: Date

  public static let lifetime: TimeInterval = 8 * 60 * 60
  /// 系统到上限自己结束的活动还在锁屏留四小时旧内容，那时已推不动它：提前这么久由 Mac 结束并清掉。
  public static let retireLead: TimeInterval = 15 * 60
  public var expiresAt: Date { startedAt.addingTimeInterval(Self.lifetime) }
  public var retireAt: Date { expiresAt.addingTimeInterval(-Self.retireLead) }
  public var isStarter: Bool { activityID.isEmpty }
  public static func recordID(device: String) -> UUID { DeterministicID.uuid("activity-destination/\(device)") }
  public static func starterID(device: String) -> UUID { DeterministicID.uuid("activity-starter/\(device)") }
}

extension ActivityDestination: Record, SyncedColumns {
  static let table = Table.activityDestinations
  static let fields: [Field] = [
    .plain("id"), .plain("device"), .plain("activityID"), .encrypted("token"), .plain("environment"), .plain("startedAt"),
    .plain("modifiedAt"),
  ]
  var bindings: [any SQLBindable] {
    [isStarter ? Self.starterID(device: device) : Self.recordID(device: device), device, activityID, token, environment, startedAt, modifiedAt]
  }
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

  /// 各台手机的推送地址（活动的与开岛的）；过期的照样读出，由发布方据此知道那只岛没了。到该收、到过期的时刻由发布方自己醒：
  /// 到点重读读到的还是这几行，订阅不会为它再叫一次。
  public func activityDestinations() throws -> [ActivityDestination] { try select(ActivityDestination.self, orderBy: "device") }

  /// 开岛的令牌系统会换：只留最新一份。
  @discardableResult
  public func recordActivityStarter(device: String, token: String, environment: String) throws -> UUID? {
    try write {
      let id = ActivityDestination.starterID(device: device)
      if let old = try find(ActivityDestination.self, id), old.token == token, old.environment == environment { return nil }
      try upsert(
        ActivityDestination(device: device, activityID: "", token: token, environment: environment, startedAt: Date(timeIntervalSince1970: 0), modifiedAt: Date.stamp),
        updating: ["token", "environment", "modifiedAt"])
      return id
    }
  }

  @discardableResult
  public func removeActivityStarter(device: String) throws -> UUID? {
    try write {
      let id = ActivityDestination.starterID(device: device)
      guard try find(ActivityDestination.self, id) != nil else { return nil }
      try db.run("DELETE FROM activityDestinations WHERE id = ?", [id])
      return id
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
