import Foundation

/// 网关读到的余额、套餐与非固定周期窗口。金额和提供方的计数字符串原样保留，不参与额度环与匀速推算。
/// 与固定周期窗口共享 AccountQuota 的授权、状态和 observedAt；失败保留上次观测，不能续期。
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
