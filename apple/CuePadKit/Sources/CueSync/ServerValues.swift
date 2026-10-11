import CloudKit
import CueStore
import Foundation

/// 服务器上每条记录里"大字段"此刻的值（只存指纹）。
///
/// 上传是整条：重建记录时每一列都 set，CKRecord 就把它们全算作改动（实测一条状态记录 `changedKeys()` 包含全部列），
/// 一条状态记录带着三百个模型的清单（约 38 KB）和命令清单，而状态每几秒就变一次。服务器已经有同样的大字段值时不再 set 它，
/// 它就不在这次上传里（`.ifServerRecordUnchanged` 保存按改动的字段发送）。
///
/// 正确性不依赖引擎线上到底只发改动的字段、还是发记录对象里有的全部字段：CloudKit 不会因为记录里没有某个键就删掉服务器上的值
/// （Apple 的 `allKeys` 存储策略文档：服务器记录可以含本地没有的键；清空要显式 set nil），所以不 set 的列在服务器上保持原样；
/// 线上粒度只决定省多少字节。
///
/// 指纹来自服务器真正有的值：别处拿到的整条记录（引擎拉取、`ZoneChangePuller` 拉取——两条路都经协调器的 `.fetched` 入口记账，冲突里的服务器版本），
/// 或本机发出并被接受的版本。错过一次记账（没记到的服务器改动）最多让下一次上传多带一个字段，不会该发的没发：
/// 指纹和本机值相等才跳过，而服务器上被别处改过时，本机上传带着旧的版本标签，会被服务器以 `serverRecordChanged` 拒绝并走冲突合并。
/// 只存在内存里：重启后每条记录的第一次上传仍是整条。小字段不存也不跳过，指纹因此少、出错面小。
struct ServerValues {
  /// 短于这个长度（UTF-8 字节）的字段每次照发。
  static let minimumBytes = 512

  private var known: [String: [String: Int]] = [:]

  /// 这一列的值和服务器上的一样：可以不 set。
  func isCurrent(_ column: String, in row: SyncRow) -> Bool {
    guard let value = row.fields[column], let hash = Self.fingerprint(value) else { return false }
    return known[row.id]?[column] == hash
  }

  /// 服务器上这条记录现在就是这个样子。
  mutating func learn(_ row: SyncRow) {
    let large = row.fields.compactMapValues(Self.fingerprint)
    known[row.id] = large.isEmpty ? nil : large
  }

  mutating func forget(_ recordName: String) { known[recordName] = nil }

  mutating func removeAll() { known = [:] }

  private static func fingerprint(_ value: SQLValue) -> Int? {
    var hasher = Hasher()
    switch value {
    case .text(let text):
      guard text.utf8.count >= minimumBytes else { return nil }
      hasher.combine(text)
    case .blob(let data):
      guard data.count >= minimumBytes else { return nil }
      hasher.combine(data)
    case .null, .int: return nil
    }
    return hasher.finalize()
  }
}
