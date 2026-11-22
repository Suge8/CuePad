import Foundation

public enum FailureKind: String, Sendable, CaseIterable {
  case network
  case quota
  case login
  case other
  case truncated

  public var retries: Bool { self == .network || self == .other || self == .truncated }

}
