import CloudKit
import Foundation

/// 一次失败该怎么办：同步层只在这里认错误，发送者、拉取器、认账号、门槛、订阅与界面状态都用这里的结论。
/// 先拆开 `partialFailure`（逐条里最要紧的那类），再看错误码，最后看底层错误：任何一层带着 URL 错误（-1009 断网、-1001 超时）都是连不上。
/// 服务器给的 `retryAfterSeconds` 只定最早什么时候再试，不改归类：CloudKit 的请求超时也带它（开发环境实测 3 秒，错误码 4、底层 -1001）。
/// 同步区不在、令牌过期、批太大这些要先改本机状态才能继续的，由各自的调用处在归类之前处理。
enum SyncFault: Equatable, Sendable {
  /// 连不上 iCloud（没有网络、超时、服务暂不可用）：显示离线，按退避重试；任何一次请求成功（连通的证据）就不再等退避，服务器给的等待照守。
  case offline(Duration?)
  /// 服务器要求等（限流、区忙）：有给的等待按它，没给按退避；连通的证据不缩短它（Apple 要求区忙指数退避）。
  case wait(Duration?)
  /// 账号与配额：状态写明（没登录、受限、暂不可用、空间不足），长退避重试；账号变化时由同步重新认。
  case account(SyncStatus)
  /// 其余：这次请求或这条记录本身的问题，进问题列表、显示同步出错，停一阵再试。
  case rejected

  init(_ error: any Error) {
    guard let error = error as? CKError else {
      self = Self.isURLError(error) ? .offline(nil) : .rejected
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

  /// 服务器给的最早重试间隔。
  var retryAfter: Duration? {
    switch self {
    case .offline(let given), .wait(let given): given
    case .account, .rejected: nil
    }
  }

  /// 一批里各条的失败合成一个：连不上压过其余（整批都会这样），其次账号，再次要等，最后才是单条的问题；同类的取服务器给的最长等待。
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

  /// 错误本身或它底下任何一层是 URL 错误。
  private static func isURLError(_ error: any Error) -> Bool {
    var current: NSError? = error as NSError
    while let error = current {
      if error.domain == NSURLErrorDomain { return true }
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}
