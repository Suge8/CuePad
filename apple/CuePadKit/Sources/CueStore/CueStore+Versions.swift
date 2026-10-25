import Foundation

/// 同一行的新版本一定比旧的大。版本就是 `modifiedAt`（毫秒）：同一毫秒里先后两次写同一行（领取与写回结果、App 与命令行各写一次），
/// 或刚收下的远端版本带着比本机时钟更晚的时间，本机这次改写就不比旧版大；服务器收下旧版后本机记下的推送版本等于它，
/// 这一版不再算待推送、永远传不上去。
///
/// 收口在库这一层：写连接每次打开时建临时触发器（`guards`，只在这个连接里、不进库结构，命令行与分享扩展开库走同一处），
/// 本机写入把版本写得不比旧的大时改成旧值 + 1。照搬远端版本（`copyingRemote`）不改：那一版就是服务器上的，
/// 改了会把自己上传的回声当成新版本再传一遍。没用每条写语句里的 `MAX(?, 旧值 + 1)`：写版本的语句有几十处，漏一处就又有这个洞。
extension CueStore {
  static let guards = """
    CREATE TEMP TABLE remoteCopy (active INTEGER NOT NULL);
    INSERT INTO remoteCopy VALUES (0);
    """ + Table.synced.map { table in
      """
      CREATE TEMP TRIGGER \(table.rawValue)_newerVersion AFTER UPDATE OF modifiedAt ON \(table.rawValue)
      WHEN new.modifiedAt <= old.modifiedAt AND (SELECT active FROM remoteCopy) = 0
      BEGIN UPDATE \(table.rawValue) SET modifiedAt = old.modifiedAt + 1 WHERE id = new.id; END;
      """
    }.joined(separator: "\n")

  /// 照搬远端的那一版：版本原样落库。在写事务里调：中途抛出时整个事务回滚，开关随之回到 0。
  func copyingRemote(_ body: () throws -> Void) throws {
    try db.exec("UPDATE remoteCopy SET active = 1")
    try body()
    try db.exec("UPDATE remoteCopy SET active = 0")
  }
}
