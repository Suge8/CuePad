import Foundation

/// 一台设备此刻开着哪个会话（同步表 `sessionViewers`，每台设备一条，只由它自己写；Cue 值班的那台 Mac 读）：会话停下时他在不在场
/// （`SessionPresence`）的一半，另一半是他最近在里面说过话。记录只有一个期限：此刻早于 `until` 就还开着 `sessionID`。
/// 开着时（App 在前台、那一页盖住这个会话、人在用：Mac 看系统多久没有键鼠，手机屏幕亮着才算前台）每 `renewal` 续一次，
/// 把期限推到最近一次有人在用的时刻加 `lifetime`；离开那一页、切到后台、将睡眠、退出时写成此刻（当场离开）。写的时机在 App 的 `SessionViewerKeeper`。
/// 到期由 Cue 的管理器按期限排一次对账，不轮询；期限是那台设备的时钟写的，各端时钟大致对准即可。
public struct SessionViewer: Equatable, Sendable {
  /// 写它的设备（Mac 的 hostID，手机的 identifierForVendor）
  public var device: String
  public var sessionID: String
  public var until: Date
  public var modifiedAt: Date

  /// 开着时多久续一次：没打招呼就消失（崩溃、断网）时最晚 `lifetime` 后算离开。
  public static let renewal: Duration = .seconds(5 * 60)
  /// 一次续期管多久，也是"人走开多久算离开"：与说过话的窗口同一个（`SessionPresence.window`）。
  public static var lifetime: TimeInterval { SessionPresence.window }

  public func isViewing(at now: Date) -> Bool { now < until }

  public static func recordID(device: String) -> UUID { DeterministicID.uuid("session-viewer/\(device)") }
}

extension SessionViewer: Record {
  static let table = Table.sessionViewers
  static let columns = ["id", "device", "sessionID", "until", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, sessionID, until, modifiedAt] }
  init(row: Row) { self.init(device: row.text(1), sessionID: row.text(2), until: row.date(3), modifiedAt: row.date(4)) }
}

extension CueStore {
  /// 这台设备写下自己开着哪个会话：`sessionID` 为 nil 是没开着任何会话（离开、后台、睡眠、退出），期限写成此刻；
  /// 开着时期限是 `activeAt`（最近一次有人在用的时刻）加 `SessionViewer.lifetime`。和库里一样就不写。返回记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordViewing(device: String, sessionID: String?, activeAt: Date) throws -> UUID? {
    try write {
      let now = timing.now()
      let id = SessionViewer.recordID(device: device)
      let current = try find(SessionViewer.self, id)
      guard sessionID != nil || current?.isViewing(at: now) == true else { return nil }
      // 库里存到毫秒：离开写成此刻要往下取整，四舍五入进位会让同一毫秒里的读仍算开着
      let left = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
      let viewer = SessionViewer(
        device: device, sessionID: sessionID ?? current?.sessionID ?? "", until: sessionID == nil ? left : activeAt + SessionViewer.lifetime,
        modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO sessionViewers (\(SessionViewer.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET sessionID = excluded.sessionID, until = excluded.until, modifiedAt = excluded.modifiedAt
        """, viewer.bindings)
      return id
    }
  }
}
