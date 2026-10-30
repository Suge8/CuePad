import Foundation

/// 确定整个操作尚未开始：等待现有目标就绪，不恢复进程、不派发探测消息。
public struct DeliveryPreparation: Sendable {
  public let reason: ShownText
  public let wait: @Sendable () async throws -> Void

  public init(reason: ShownText, wait: @escaping @Sendable () async throws -> Void) {
    self.reason = reason
    self.wait = wait
  }

  public static let expired = ShownText("准备超时，尚未派发，不会自动发送")
  public static let abandoned = ShownText("请求已放弃，尚未派发")
  public static let ready = ShownText("准备就绪，等待派发")
}

/// 派发条件是能力约束，不把一次就绪通知当作后续派发许可。
public enum DeliveryAdmission: Sendable {
  case ready
  case existingTarget
  case waiting(DeliveryPreparation)
}
