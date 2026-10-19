import Foundation

/// 一台设备此刻开着哪个会话（同步表 `sessionViewers`，每台设备一条，只由它自己写；Cue 值班的那台 Mac 读）：会话停下时他在不在场
/// （`SessionPresence`）的一半，另一半是他最近在里面说过话。只在开着的会话变了时写一次（打开、离开、换一个），没有心跳：
/// 开着是 App 在前台、那一页盖住这个会话、有人在用（Mac 屏幕亮着、没锁；手机前台活跃就是屏幕亮着），不再开着时写 nil（离开那一页、
/// 切到后台、锁屏或屏幕睡了、将睡眠、退出）。写的时机在 App 的 `SessionViewerKeeper`。
/// 没打招呼就消失的那一下（崩溃、断电）只有 Mac 兜得住：Mac 的这条只在那台 Mac 在线（`MacPresence`）时算数，在线记录到期就不算了；
/// 手机崩在前台的那条留到它下次打开时改写。
public struct SessionViewer: Equatable, Sendable {
  /// 写它的设备（Mac 的 hostID，手机的 identifierForVendor）
  public var device: String
  /// 开着的会话（Pi 的会话 id）；没开着为 nil
  public var sessionID: String?
  public var modifiedAt: Date

  public static func recordID(device: String) -> UUID { DeterministicID.uuid("session-viewer/\(device)") }
}

extension SessionViewer: Record {
  static let table = Table.sessionViewers
  static let columns = ["id", "device", "sessionID", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, sessionID, modifiedAt] }
  init(row: Row) { self.init(device: row.text(1), sessionID: row.textOrNil(2), modifiedAt: row.date(3)) }
}

extension CueStore {
  /// 此刻开着会话、且算数的那几条（`SessionViewer` 的规则：Mac 的要那台在线，在线时登记到期重读，订阅它的到点自己变）。
  public func sessionViewers() throws -> [SessionViewer] {
    try select(SessionViewer.self, where: "sessionID IS NOT NULL", [], orderBy: "id").filter { viewer in
      try find(MacPresence.self, MacPresence.recordID(host: viewer.device)) == nil || macOnline(viewer.device)
    }
  }

  /// 这台设备写下自己开着哪个会话（nil：没开着）。和库里一样就不写。返回记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordViewing(device: String, sessionID: String?) throws -> UUID? {
    try write {
      let id = SessionViewer.recordID(device: device)
      let current = try find(SessionViewer.self, id)
      guard current.map({ $0.sessionID != sessionID }) ?? (sessionID != nil) else { return nil }
      let viewer = SessionViewer(device: device, sessionID: sessionID, modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO sessionViewers (\(SessionViewer.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET sessionID = excluded.sessionID, modifiedAt = excluded.modifiedAt
        """, viewer.bindings)
      return id
    }
  }
}
