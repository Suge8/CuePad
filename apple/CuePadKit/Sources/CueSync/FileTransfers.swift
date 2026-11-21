import Foundation
import Synchronization

public struct FileTransfer: Equatable, Sendable {
  public enum Direction: Sendable { case upload, download }
  public let direction: Direction
  public let fraction: Double

  public init(direction: Direction, fraction: Double) {
    self.direction = direction
    self.fraction = fraction
  }
}

public enum FileFetchFailure: Error, Equatable, Sendable {
  case notSyncing
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

/// 回调很密（CloudKit 约 0.26 秒一次），每个文件只在多走了一成的百分之一或开始、结束时给出新快照，订阅的界面不跟着每个回调重画。
final class TransferBoard: Sendable {
  private let board = Mutex<[String: FileTransfer]>([:])
  private let snapshots = Broadcast(latest: [String: FileTransfer]())
  static let step = 0.01

  var stream: AsyncStream<[String: FileTransfer]> { snapshots.stream() }

  func set(_ key: String, _ direction: FileTransfer.Direction, _ fraction: Double) {
    let next = FileTransfer(direction: direction, fraction: min(max(fraction, 0), 1))
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
