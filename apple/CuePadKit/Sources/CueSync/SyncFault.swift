import CloudKit
import Foundation

/// 同步层只在这里认错误：任何一层带着 URL 错误（-1009 断网、-1001 超时）都是连不上。
/// 服务器给的 `retryAfterSeconds` 只定最早什么时候再试，不改归类：CloudKit 的请求超时也带它（开发环境实测 3 秒，错误码 4、底层 -1001）。
/// 同步区不在、令牌过期、批太大这些要先改本机状态才能继续的，由各自的调用处在归类之前处理。
enum SyncFault: Equatable, Sendable {
  case offline(Duration?)
  /// 连通的证据不缩短它：Apple 要求区忙指数退避。
  case wait(Duration?)
  case account(SyncStatus)
  case rejected

  init(_ error: any Error) {
    guard let error = error as? CKError else {
      // 请求被取消（时限、赛跑输了的那路）同 CloudKit 的 operationCancelled：再试就是
      self = Self.isURLError(error) ? .offline(nil) : error is CancellationError ? .wait(nil) : .rejected
      return
    }
    if error.code == .partialFailure, let items = error.partialErrorsByItemID?.values, !items.isEmpty {
      self = items.map(SyncFault.init).reduce(nil) { SyncFault.merge($0, $1) } ?? .rejected
      return
    }
    let given = error.retryAfterSeconds.map { Duration.seconds($0) }
    switch error.code {
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .serverResponseLost: self = .offline(given)
    case .requestRateLimited, .zoneBusy, .operationCancelled, .batchRequestFailed: self = .wait(given)
    case .notAuthenticated: self = .account(.noAccount)
    case .managedAccountRestricted: self = .account(.accountRestricted)
    case .accountTemporarilyUnavailable: self = .account(.accountUnavailable)
    case .quotaExceeded: self = .account(.quotaExceeded)
    default: self = Self.isURLError(error) ? .offline(given) : given.map { .wait($0) } ?? .rejected
    }
  }

  var isOffline: Bool {
    if case .offline = self { true } else { false }
  }

  var isWait: Bool {
    if case .wait = self { true } else { false }
  }

  func sameKind(as other: SyncFault) -> Bool {
    switch (self, other) {
    case (.offline, .offline), (.wait, .wait), (.rejected, .rejected): true
    case (.account(let a), .account(let b)): a == b
    default: false
    }
  }

  /// 写进日志的归类（只进日志、不上界面，不译）。
  var label: String {
    switch self {
    case .offline: "连不上 iCloud"
    case .wait: "服务器要求等"
    case .account(let status): "账号（\(status)）"
    case .rejected: "被拒"
    }
  }

  var retryAfter: Duration? {
    switch self {
    case .offline(let given), .wait(let given): given
    case .account, .rejected: nil
    }
  }

  static func merge(_ merged: SyncFault?, _ next: SyncFault) -> SyncFault {
    guard let merged else { return next }
    let given = [merged.retryAfter, next.retryAfter].compactMap { $0 }.max()
    switch (merged, next) {
    case (.wait, .wait): return .wait(given)
    case (.offline, .offline): return .offline(given)
    default: return merged.rank >= next.rank ? merged : next
    }
  }

  private var rank: Int {
    switch self {
    case .rejected: 0
    case .wait: 1
    case .account: 2
    case .offline: 3
    }
  }

  private static func isURLError(_ error: any Error) -> Bool {
    var current: NSError? = error as NSError
    while let error = current {
      if error.domain == NSURLErrorDomain { return true }
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}
