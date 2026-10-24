import CryptoKit
import notify
import Foundation
import Synchronization

/// 跨进程变更通知（Darwin 通知，系统事件，不轮询）：任一进程提交写事务后，按碰到的每张表各 post 一个名字，
/// 其他进程的 `CueStore` 只叫醒读这些表的订阅（`externalChangeNotified`）。本进程自己的通知也会收到，靠 `PRAGMA data_version` 滤掉。
/// 名称按库文件的真实路径区分，隔离目录互不干扰。iOS 上带 App Group 前缀（沙盒内的主 App 与扩展只能收发这个前缀的通知）；
/// Mac 上没有沙盒，前缀不随身份：自己编的命令行不在 App 包里、认不出身份（`AppIdentity.unbundled`），开同一个开发库时也要和开发版 App 互通。
enum ChangeNotification {
  #if os(iOS)
  static let prefix = AppIdentity.appGroup
  #else
  static let prefix = "cuepad"
  #endif

  static func names(forDatabase url: URL) -> [Table: String] {
    let path = url.resolvingSymlinksInPath().standardized.path
    let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).hex
    return Dictionary(uniqueKeysWithValues: Table.allCases.map { ($0, "\(prefix).store.\(digest).\($0.rawValue)") })
  }

  static func post(_ name: String) { notify_post(name) }
}

extension Sequence<UInt8> {
  var hex: String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
  }
}

/// 订阅每张表的 Darwin 通知：收到的表攒进 `drain`，`events` 只说"有新的"（突发合并为一次）；释放时注销。
final class ChangeListener: Sendable {
  let events: AsyncStream<Void>
  private let posted = Posted()
  private let tokens: [Int32]
  private let finish: @Sendable () -> Void

  init(names: [Table: String]) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let queue = DispatchQueue(label: "CueStore.changes", qos: .utility)
    var tokens: [Int32] = []
    events = stream
    finish = { continuation.finish() }
    for (table, name) in names {
      var token: Int32 = 0
      notify_register_dispatch(name, &token, queue) { [posted] _ in
        posted.tables.withLock { _ = $0.insert(table) }
        continuation.yield()
      }
      tokens.append(token)
    }
    self.tokens = tokens
  }

  /// 上次取走之后收到通知的表。
  func drain() -> Set<Table> {
    posted.tables.withLock { tables in
      defer { tables = [] }
      return tables
    }
  }

  deinit {
    for token in tokens { notify_cancel(token) }
    finish()
  }
}

private final class Posted: Sendable {
  let tables = Mutex<Set<Table>>([])
}
