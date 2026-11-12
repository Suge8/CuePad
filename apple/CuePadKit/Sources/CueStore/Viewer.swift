import Foundation

/// 一台设备此刻开着哪些页（同步表 `sessionViewers`，每台设备一条，只由它自己写）：开着的会话页与 Cue 页，与他最近一次来到这台的时刻。
/// 读它的是提示到不到他（`CueStore.reaches`）：他在某台 Mac 上开着那一页，手机推送标志不置、Mac 不发通知。
///
/// 他此刻在哪台设备前只有一个判断：最近一次来到哪台（`arrivedAt` 最晚的那台，`CueStore.leftFor`），同即时通讯"以最近有真人操作的那台为准"。
/// 来到一台是一次真人操作：手机是 App 回到前台；Mac 是他在别的设备上之后，回到这台的第一下键盘鼠标。Mac 读到别的设备比自己来得晚，就算人不在跟前
/// （`ViewerKeeper.Away.elsewhere`），与走开、锁屏一样不算开着任何页：Mac 窗口露着、十分钟内动过，也挡不住他拿起手机之后的推送。
///
/// 开着哪些页只在变了时写一次，没有心跳：开着是那一页在屏上、有人在用，不再开着时写空。具体判断（Mac 上是人看得到主窗口，手机是 App 前台活跃）与写的时机在 App 的 `ViewerKeeper`、`AppServices.seesMainWindow`。
/// 没打招呼就消失的那一下（崩溃、断电）只有 Mac 兜得住：Mac 的这条只在那台 Mac 在线（`MacPresence`）时算数，在线记录到期就不算了；
/// 手机崩在前台、进后台时没网传不出去的那条会停在"开着"，留到它下次打开时改写。所以提示只认 Mac 开着的页：手机那条一停住，
/// 所有推送都会被它挡掉；手机的那条只用来说明他来过手机（让 Mac 让位，只会多推、不会少推），手机自己前台收到推送时按本机当场开着哪些页定弹不弹（`AlertCenter`）。
public struct Viewer: Equatable, Sendable {
  public var device: String
  public var sessionIDs: Set<String>
  public var cue: Bool
  public var modifiedAt: Date
  /// 他最近一次来到这台的时刻（`CueStore.arrive`）；还没来过为 nil。只往后挪，开着的页变了、人走开都不动它。
  public var arrivedAt: Date? = nil

  public static func recordID(device: String) -> UUID { DeterministicID.uuid("session-viewer/\(device)") }
}

extension Viewer: Record {
  static let table = Table.sessionViewers
  static let columns = ["id", "device", "sessionIDs", "modifiedAt", "cue", "arrivedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(device: device), device, JSONColumn.encodeList(sessionIDs.sorted()), modifiedAt, cue, arrivedAt] }
  init(row: Row) {
    self.init(device: row.text(1), sessionIDs: Set(JSONColumn.decodeList(String.self, from: row.textOrNil(2))), cue: row.bool(4), modifiedAt: row.date(3), arrivedAt: row.dateOrNil(5))
  }
}

extension CueStore {
  /// 他此刻在某台在线的 Mac 上开着这一页（`opens`）：提示到不到他的一半（`reaches`）。手机的那条不算（理由见 `Viewer`）。
  func watchedOnMac(_ opens: (Viewer) -> Bool) throws -> Bool {
    try viewing().contains { try opens($0) && macOnline($0.device) }
  }

  /// 这台设备写下自己开着哪些页（会话页、Cue 页；都没开着就都空）。和库里一样就不写。返回记录 id（立即上传用），没写为 nil。
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

  /// 他来到了这台设备（手机回到前台、Mac 在他去过别的设备之后有了键盘鼠标）：记下来到的时刻，开着哪些页不动。
  /// 时刻比哪台记下的都晚（至少晚一毫秒）：两台的钟差一点，最后来到的这台也一定是最晚的那台。返回记录 id（立即上传用）。
  @discardableResult
  public func arrive(device: String) throws -> UUID {
    try write {
      let id = Viewer.recordID(device: device)
      let latest = try db.first("SELECT max(arrivedAt) FROM sessionViewers") { $0.dateOrNil(0) }.flatMap(\.self)
      let now = Date.stamp
      let at = latest.map { max(now, $0.addingTimeInterval(0.001)) } ?? now
      let current = try find(Viewer.self, id)
      try upsert(
        Viewer(device: device, sessionIDs: current?.sessionIDs ?? [], cue: current?.cue ?? false, modifiedAt: at, arrivedAt: at),
        updating: ["arrivedAt", "modifiedAt"])
      return id
    }
  }

  /// 他最近一次来到的是别的设备、不是这台（`Viewer` 的唯一判断）：别的设备记下的来到时刻晚于这台的（这台还没来过时，别的来过就算）。
  public func leftFor(device: String) throws -> Bool {
    try db.first(
      """
      SELECT 1 FROM sessionViewers WHERE device != ?1 AND arrivedAt > coalesce((SELECT arrivedAt FROM sessionViewers WHERE device = ?1), -1) LIMIT 1
      """, [device]) { _ in true } ?? false
  }

  private func viewing() throws -> [Viewer] { try select(Viewer.self, where: "json_array_length(sessionIDs) > 0 OR cue", [], orderBy: "id") }
}
