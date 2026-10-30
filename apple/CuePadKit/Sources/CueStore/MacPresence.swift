import Foundation

/// 一台 Mac 在不在线（同步表 `macPresence`，每台 Mac 一条，只由它自己写；手机与别的 Mac 只读）：Mac 在不在、Cue 在不在值班
/// （`CueProfile.onDuty`、Cue 页的"在睡觉"）都只从这里推出。记录只有一个期限：此刻早于 `onlineUntil` 就在线，没有记录是不在线。
/// 醒着的 Mac 每 `renewal` 续一次，把期限推到此刻加 `lifetime`；将睡眠、退出时写成此刻（当场离线）；醒来、启动立即续期
/// （写的时机在 App 的 `MacPresenceKeeper`）。到期由订阅重读（`expire(at:)`），不轮询；期限是那台 Mac 的时钟写的，各端时钟大致对准即可。
public struct MacPresence: Equatable, Sendable {
  public var hostID: String
  public var onlineUntil: Date
  public var bootID: String?
  public var modifiedAt: Date

  /// 醒着时多久续一次。在线记录只在 Mac 没打招呼就消失时（崩溃、断电、断网、将睡眠那一条没传出去）靠期限兜底，
  /// 正常的睡眠与退出当场写离线；取 5 分钟：兜底时最晚 `lifetime`（10 分钟）后在等 Cue 的提问回到等你，
  /// 而续期只是每台醒着的 Mac 每小时 12 次小上传。再短，手机收到的同步推送随之翻倍（取舍见 docs/sync.md「Mac 在线」）。
  public static let renewal: Duration = .seconds(5 * 60)
  /// 一次续期管多久：两个续期间隔。晚一次续期（上传慢、系统忙时定时器推迟）不会被说成离线，错过两次才算。
  public static let lifetime: TimeInterval = 2 * Double(renewal.components.seconds)

  func isOnline(at now: Date) -> Bool { now < onlineUntil }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("mac-presence/\(host)") }
}

extension MacPresence: Record {
  static let table = Table.macPresence
  static let columns = ["id", "hostID", "onlineUntil", "modifiedAt", "bootID"]
  var bindings: [any SQLBindable] { [Self.recordID(host: hostID), hostID, onlineUntil, modifiedAt, bootID] }
  init(row: Row) { self.init(hostID: row.text(1), onlineUntil: row.date(2), bootID: row.textOrNil(4), modifiedAt: row.date(3)) }
}

extension CueStore {
  /// 这台 Mac 写下自己在不在线：醒着写到此刻加 `MacPresence.lifetime`，不醒（将睡眠、退出）写成此刻。返回记录 id（立即上传用）。
  /// `awake` 在写的这一刻才读：定时续期与将睡眠的写可能交错，后执行的那次也按最新的醒睡写，刚标的离线不会被一次晚到的续期续上。
  @discardableResult
  public func recordMacPresence(host: String, bootID: String? = SystemBoot.id, awake: @Sendable () -> Bool) throws -> UUID {
    try write {
      let now = timing.now()
      // 库里存到毫秒：离线写成此刻要往下取整，四舍五入进位会让同一毫秒里的读仍算在线
      let offline = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
      let presence = MacPresence(
        hostID: host, onlineUntil: awake() ? now.addingTimeInterval(MacPresence.lifetime) : offline, bootID: bootID, modifiedAt: Date.stamp)
      try upsert(presence, updating: ["onlineUntil", "modifiedAt", "bootID"])
      return MacPresence.recordID(host: host)
    }
  }

  /// 那台 Mac 此刻在不在线（`MacPresence`）；在线时登记到期重读（`expire(at:)`），订阅它的到点自己变成不在线。
  public func macOnlineUntil(_ host: String) throws -> Date? {
    guard let presence = try find(MacPresence.self, MacPresence.recordID(host: host)), presence.isOnline(at: timing.now()) else { return nil }
    expire(at: presence.onlineUntil)
    return presence.onlineUntil
  }

  public func macOnline(_ host: String) throws -> Bool { try macOnlineUntil(host) != nil }
}
