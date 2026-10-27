import Foundation
import Synchronization

/// 一个附件文件此刻在路上：往 iCloud 传（`upload`）或从 iCloud 取（`download`），传了几成（0–1）。
public struct FileTransfer: Equatable, Sendable {
  public enum Direction: Sendable { case upload, download }
  public let direction: Direction
  public let fraction: Double

  public init(direction: Direction, fraction: Double) {
    self.direction = direction
    self.fraction = fraction
  }
}

/// 没能把文件取到本机。网络与 iCloud 的失败原样抛出（CKError），这里是同步层自己的结论。
public enum FileFetchFailure: Error, Equatable, Sendable {
  /// 这台此刻不同步（没登录、受限、停下等你决定或要更新），取不了。
  case notSyncing
  /// iCloud 里这个文件坏了（没有文件、内容与哈希不符），已进问题列表；再取也一样。
  case damaged
}

extension FileFetchFailure: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notSyncing: String(localized: "这台现在没在同步，取不了 iCloud 里的文件")
    case .damaged: String(localized: "iCloud 里的这个文件坏了，取不下来")
    }
  }
}

/// 文件那一路的进度板：按附件的 key 记在路上的，一处写、多处订阅（`CloudSync.fileTransfers`）。
/// 回调很密（CloudKit 约 0.26 秒一次），每个文件只在多走了一成的百分之一或开始、结束时给出新快照，订阅的界面不跟着每个回调重画。
final class TransferBoard: Sendable {
  private let board = Mutex<[String: FileTransfer]>([:])
  private let snapshots = Broadcast(latest: [String: FileTransfer]())
  static let step = 0.01

  var stream: AsyncStream<[String: FileTransfer]> { snapshots.stream() }

  func set(_ key: String, _ direction: FileTransfer.Direction, _ fraction: Double) {
    let next = FileTransfer(direction: direction, fraction: min(max(fraction, 0), 1))
    // 在锁里给出：两路的回调同时来，快照不会先后颠倒
    board.withLock { board in
      if let last = board[key], last.direction == direction, abs(last.fraction - next.fraction) < Self.step, next.fraction < 1 { return }
      board[key] = next
      snapshots.yield(board)
    }
  }

  func clear(_ key: String) {
    board.withLock { board in
      guard board.removeValue(forKey: key) != nil else { return }
      snapshots.yield(board)
    }
  }
}
