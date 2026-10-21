import CryptoKit
import notify
import Foundation

/// 跨进程变更通知（Darwin 通知，系统事件，不轮询）。任一进程提交写事务后 post，
/// 其他进程的 `CueStore` 收到后用 `PRAGMA data_version` 判断是否真有别的连接提交过——
/// 本进程自己的提交不改变该值，因此自己的通知、合并的通知、无关的通知都不会产生多余的重读。
/// 名称带 App Group 前缀（沙盒内的进程只能收发这个前缀的通知），并按库文件的真实路径区分，隔离目录互不干扰。
enum ChangeNotification {
  static func name(forDatabase url: URL) -> String {
    let path = url.resolvingSymlinksInPath().standardized.path
    let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).hex
    return "\(LibraryLocation.appGroupIdentifier).store.\(digest)"
  }

  static func post(_ name: String) { notify_post(name) }
}

extension Sequence<UInt8> {
  var hex: String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
  }
}

/// 订阅一个 Darwin 通知，以 `AsyncStream` 交出事件（突发合并为一次）；释放时注销。
final class ChangeListener: Sendable {
  let events: AsyncStream<Void>
  private let token: Int32
  private let finish: @Sendable () -> Void

  init(name: String) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var token: Int32 = 0
    notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in continuation.yield() }
    events = stream
    self.token = token
    finish = { continuation.finish() }
  }

  deinit {
    notify_cancel(token)
    finish()
  }
}
