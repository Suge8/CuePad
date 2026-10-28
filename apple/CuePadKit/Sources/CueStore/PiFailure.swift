import Foundation

/// 会话出错的种类（`PiSessionState.failure`，Mac 写、各端只读）：会话页回复框上方那块出错与看板卡上写的原因只按它分，不各自看原因文字。
/// 种类只在 Mac 记下会话状态时按 Agent 报的原因定一次（`init(reason:)`，`CueStore.writePiState`，四家同一处）；
/// Agent 自己会重试的暂时性错（断网、超时、过载、限流）重试用尽才落到这里。
public enum PiFailure: String, Sendable, CaseIterable {
  /// 连不上模型服务：网络、超时、服务过载或限流，Agent 自己重试用尽。重跑这一轮。
  case network
  /// 额度或计费用完：换个模型接着做。
  case quota
  /// 登录失效：要在 Mac 上重新登录，或换个模型接着做。
  case login
  /// 其余（请求被拒、模型报错）：重跑这一轮。
  case other

  /// 重跑这一轮有用；额度与登录卡住的要换模型。
  public var retries: Bool { self == .network || self == .other }

  /// 按 Agent 报的原因文字分（唯一的分法）：先认额度与登录（它们常带 429、403 这类也像暂时性的码），再认连不上，其余归其余。
  /// 连不上的说法同 Pi 自己会重试的那一批（pi-ai 的 `isRetryableAssistantError`），额度的同它认作不可重试的限额。
  public init(reason: String?) {
    let text = reason ?? ""
    self = Self.patterns.first { text.range(of: $0.pattern, options: .regularExpression) != nil }?.failure ?? .other
  }

  private static let patterns: [(failure: PiFailure, pattern: String)] = [
    (.quota, #"(?i)insufficient_quota|quota|billing|usage.?limit|out of budget|credit balance|available balance|额度"#),
    (.login, #"(?i)\b401\b|unauthori[sz]ed|authenticat|invalid.?(x-)?api.?key|api key|not logged in|log ?in|oauth|token (has )?expired|登录"#),
    (.network, #"(?i)overloaded|server_busy|busy|capacity|rate.?limit|too many requests|\b(429|5\d\d)\b|unavailable|server.?error|internal.?error|network|connection|fetch failed|getaddrinfo|ENOTFOUND|EAI_AGAIN|ECONNRESET|socket|timed? ?out|terminated|upstream|超时|网络"#),
  ]
}
