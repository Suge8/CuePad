import Foundation

/// 宿主认证事实与不泄密的授权分区。分区缺失时不能关联任何数值额度；令牌轮换也开始新观测。
public struct PiAccount: Sendable, Equatable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable { case oauth, apiKey }
  public let kind: Kind
  public let scope: String?
  /// 实际网关地址与请求授权的不可逆分区；原生订阅为 nil。
  public let source: String?
  /// 网关额度的完整上游 provider（可含远端前缀）；模型的请求身份不填。
  public let route: String?
  public let name: String?

  public init(kind: Kind, scope: String? = nil, source: String? = nil, route: String? = nil, name: String? = nil) {
    self.kind = kind
    self.scope = scope
    self.source = source
    self.route = route
    self.name = name
  }

  public func matches(_ other: PiAccount?) -> Bool {
    scope != nil && kind == other?.kind && scope == other?.scope && source == other?.source
  }

  public func label(provider: String) -> String? {
    if source != nil { return name }
    return switch (provider, kind) {
    case ("openai", .oauth): String(localized: "使用 ChatGPT 套餐")
    case ("openai", .apiKey): String(localized: "OpenAI API 按量计费")
    default: nil
    }
  }

  public func usageURL(provider: String) -> URL? {
    source == nil && provider == "openai" && kind == .oauth ? Self.chatGPTUsageURL : nil
  }

  public static let chatGPTUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
}

public enum QuotaStatus: String, Sendable, Codable {
  case observed, unobserved, unsupported, failed
}
