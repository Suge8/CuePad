import Foundation

/// 会话出错的种类（`PiSessionState.failure`，Mac 写、各端只读）：会话页回复框上方那块出错与看板卡上写的原因只按它分，不各自看原因文字。
/// 种类只在 Mac 的桥上按 Agent 报的原文归一次类（`PiErrorSummary.failure`，四家同一处），随会话记录同步；
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
  /// 达到输出长度上限，文字已保留但这一轮未完成。
  case truncated

  /// 重跑这一轮有用；额度与登录卡住的要换模型。
  public var retries: Bool { self == .network || self == .other || self == .truncated }

}
