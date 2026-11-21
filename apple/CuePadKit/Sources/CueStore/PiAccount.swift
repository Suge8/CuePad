import Foundation

public struct PiAccount: Sendable, Equatable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable { case oauth, apiKey }
  public let kind: Kind
  public let scope: String?
  public let source: String?
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
