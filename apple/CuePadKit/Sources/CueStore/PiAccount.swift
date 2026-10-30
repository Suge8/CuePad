import Foundation

/// 宿主认证事实与不泄密的授权分区。分区缺失时不能关联任何数值额度；令牌轮换也开始新观测。
public struct PiAccount: Sendable, Equatable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable { case oauth, apiKey }
  public let kind: Kind
  public let scope: String?

  public init(kind: Kind, scope: String? = nil) {
    self.kind = kind
    self.scope = scope
  }

  public func matches(_ other: PiAccount?) -> Bool {
    scope != nil && self == other
  }

  public func label(provider: String) -> String? {
    switch (provider, kind) {
    case ("openai", .oauth): String(localized: "使用 ChatGPT 套餐")
    case ("openai", .apiKey): String(localized: "OpenAI API 按量计费")
    default: nil
    }
  }

  public func usageURL(provider: String) -> URL? {
    provider == "openai" && kind == .oauth ? Self.chatGPTUsageURL : nil
  }

  public static let chatGPTUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
}

public enum QuotaStatus: String, Sendable, Codable {
  case observed, unobserved, unsupported, failed
}
