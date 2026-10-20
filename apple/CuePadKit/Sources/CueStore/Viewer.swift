import Foundation

/// 一台设备此刻开着哪一页（同步表 `sessionViewers`，每台设备一条，只由它自己写）：开着的会话页与 Cue 页。两处读它——
/// - 会话停下时他在不在场（`SessionPresence`）的一半，另一半是他最近在里面说过话；Cue 值班的那台 Mac 读。
/// - 提示到不到他（`CueStore.isWatched`）：他在某台 Mac 上开着那一页，手机推送标志不置、Mac 不发通知。
///
/// 只在开着的页变了时写一次（打开、离开、换一个），没有心跳：开着是那一页在屏上、有人在用（Mac 屏幕亮着、没锁；
/// 手机前台活跃就是屏幕亮着）；会话页另要 App 在前台，Cue 页在 Mac 上窗口露着就算、有没有焦点都一样（露着的新消息当场就读掉了，`CueViewing`），不再开着时写空（离开那一页、切到后台、锁屏或屏幕睡了、将睡眠、退出）。写的时机在 App 的 `ViewerKeeper`。
/// 没打招呼就消失的那一下（崩溃、断电）只有 Mac 兜得住：Mac 的这条只在那台 Mac 在线（`MacPresence`）时算数，在线记录到期就不算了；
/// 手机崩在前台、进后台时没网传不出去的那条会停在"开着"，留到它下次打开时改写。所以提示只认 Mac 的：手机那条一停住，
/// 所有推送都会被它挡掉；手机自己前台收到推送时按本机当场开着哪一页定弹不弹（`AlertCenter`）。
public struct Viewer: Equatable, Sendable {
  /// 写它的设备（Mac 的 hostID，手机的 identifierForVendor）
  public var device: String
  /// 开着的会话页（Pi 的会话 id）；没开着为 nil
  public var sessionID: String?
  /// 开着 Cue 页（iPad 上可以和会话页同时在屏上）
  public var cue: Bool
  public var modifiedAt: Date

  public static func recordID(device: String) -> UUID { DeterministicID.uuid("session-viewer/\(device)") }
}

extension Viewer: Record {
  static let table = Table.sessionViewers
  static let columns = ["id", "device", "sessionID", "modifiedAt", "cue"]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, sessionID, modifiedAt, cue] }
  init(row: Row) { self.init(device: row.text(1), sessionID: row.textOrNil(2), cue: row.bool(4), modifiedAt: row.date(3)) }
}

/// 一条提示说的是什么：一个会话（会话记录 id，`PiSessionState.id`；锁屏通知只带它），或 Cue。
public enum AlertSubject: Hashable, Sendable {
  case session(UUID)
  case cue
}

extension CueStore {
  /// 此刻开着页、且算数的那几条（`Viewer` 的规则：Mac 的要那台在线，在线时登记到期重读，订阅它的到点自己变）。
  public func viewers() throws -> [Viewer] {
    try viewing().filter { viewer in
      try find(MacPresence.self, MacPresence.recordID(host: viewer.device)) == nil || macOnline(viewer.device)
    }
  }

  /// 他此刻正看着这条提示说的东西：某台在线的 Mac 开着那个会话页或 Cue 页（`Viewer`）。看着就不提示——手机推送标志
  /// （`PiStateRecorder`、`insertCueMessage`）与 Mac 的通知（`AlertCenter`）都只问这一处。手机的那条不算（理由见 `Viewer`）。
  public func isWatched(_ subject: AlertSubject) throws -> Bool {
    try viewing().contains { viewer in
      let opens = switch subject {
      case .cue: viewer.cue
      case .session(let id): viewer.sessionID.map { PiSessionState.recordID(sessionID: $0) } == id
      }
      return try opens && macOnline(viewer.device)  // 手机没有在线记录，不算
    }
  }

  /// 这台设备写下自己开着哪一页（会话页、Cue 页；都没开着就都空）。和库里一样就不写。返回记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordViewing(device: String, sessionID: String?, cue: Bool) throws -> UUID? {
    try write {
      let id = Viewer.recordID(device: device)
      let current = try find(Viewer.self, id)
      guard current.map({ $0.sessionID != sessionID || $0.cue != cue }) ?? (sessionID != nil || cue) else { return nil }
      let viewer = Viewer(device: device, sessionID: sessionID, cue: cue, modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO sessionViewers (\(Viewer.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET sessionID = excluded.sessionID, cue = excluded.cue, modifiedAt = excluded.modifiedAt
        """, viewer.bindings)
      return id
    }
  }

  /// 开着页的那几条（还没按在线筛）。
  private func viewing() throws -> [Viewer] { try select(Viewer.self, where: "sessionID IS NOT NULL OR cue", [], orderBy: "id") }
}
