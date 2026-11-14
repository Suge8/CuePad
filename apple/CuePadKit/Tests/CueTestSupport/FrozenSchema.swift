import Foundation

/// 发出过的旧结构的新库，冻结在这里、不随结构改：升级验收从它们起步（`RawDB.restore`），`SchemaUpgradeTests` 核对从每一份升上来的库与新库一致。
/// 要从别的版本起步时，用那时的代码建一个新库、导出成一份加进来，不手写降级。
public enum FrozenSchema {
  public static let versions = [72, 77, 90, 92]

  public static func sql(_ version: Int) -> String {
    switch version {
    case 72: v72
    case 77: v77
    case 90: v90
    case 92: v92
    default: preconditionFailure("没有冻结的结构 \(version)，有的是 \(versions)")
    }
  }
}

extension RawDB {
  /// 把这个库就地换成 `version` 那一版的结构（`FrozenSchema`），数据按表名与列名搬过去、rowid 一并保留，那一版没有的表与列丢掉。
  /// 只换结构：升级步骤改写过的数据要旧写法的，调用方自己写回去。
  public func restore(version: Int) throws {
    let work = FileManager.default.temporaryDirectory.appending(path: "cuepad-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let layout = RawDB(work.appending(path: "layout.db")), data = RawDB(work.appending(path: "data.db"))
    try layout.exec(FrozenSchema.sql(version))
    try exec("VACUUM INTO '\(data.path)'")

    let tables = try data.rows("SELECT name FROM pragma_table_list WHERE schema = 'main' AND type IN ('table', 'virtual') AND name NOT LIKE 'sqlite_%' ORDER BY type = 'table'")
    let shadow = Set(try layout.rows("SELECT name FROM pragma_table_list WHERE type = 'shadow'").map { $0[0] })
    let objects = try layout.rows("SELECT type, name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY rowid").filter { !shadow.contains($0[1]) }
    var script = ["ATTACH '\(data.path)' AS old;", "BEGIN IMMEDIATE;"]
    script += tables.map { "DROP TABLE IF EXISTS main.\"\($0[0])\";" }  // 虚表在前：它的影子表随它删
    for object in objects where object[0] == "table" {
      script.append(object[2] + ";")
      let table = object[1]
      guard let kept = try data.rows("SELECT wr FROM pragma_table_list WHERE schema = 'main' AND name = '\(table)'").first else { continue }
      let wanted = Set(try layout.rows("SELECT name FROM pragma_table_info('\(table)')").map { $0[0] })
      let columns = try data.rows("SELECT name FROM pragma_table_info('\(table)')").map { $0[0] }.filter(wanted.contains)
      let layoutWithoutRowid = try layout.rows("SELECT wr FROM pragma_table_list WHERE name = '\(table)'").first?[0] != "0"
      let rowid = kept[0] == "0" && !layoutWithoutRowid
      let list = ((rowid ? ["rowid"] : []) + columns.map { "\"\($0)\"" }).joined(separator: ", ")
      script.append("INSERT INTO main.\"\(table)\" (\(list)) SELECT \(list) FROM old.\"\(table)\";")
    }
    script += objects.filter { $0[0] != "table" }.map { $0[2] + ";" }
    script += ["PRAGMA user_version = \(version);", "COMMIT;", "DETACH old;"]
    try exec(script.joined(separator: "\n"))
  }
}
