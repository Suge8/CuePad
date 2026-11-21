import Foundation

public struct QuotaDetails: Codable, Equatable, Sendable {
  public var kind: String
  public var plan: String?
  public var balance: String?
  public var values: [Value]

  public struct Value: Codable, Equatable, Sendable {
    public var name: String
    public var display: String?
    public var used: Double?
    public var unlimited: Bool?
    public var balance: Double?
    public var unit: String?
    public var resetsAt: Date?
  }

  public var hasReading: Bool { balance != nil || !values.isEmpty }
}
