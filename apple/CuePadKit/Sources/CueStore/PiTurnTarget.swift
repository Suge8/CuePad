import Foundation

/// 停止请求冻结的实际回合；沿既有 DeliveryRequest.content 投送，不另建状态表。
/// host/boot/session 防止改投，delivery 证明原消息，turnStartedAtMilliseconds 区分同一投送后续的模型回合。
public struct PiTurnTarget: Codable, Hashable, Sendable {
  public let hostID: String
  public let bootID: String
  public let sessionID: String
  public let deliveryID: UUID
  public let turnStartedAtMilliseconds: Int64

  public init(hostID: String, bootID: String, sessionID: String, deliveryID: UUID, turnStartedAtMilliseconds: Int64) {
    self.hostID = hostID
    self.bootID = bootID
    self.sessionID = sessionID
    self.deliveryID = deliveryID
    self.turnStartedAtMilliseconds = turnStartedAtMilliseconds
  }

  public var content: String { JSONColumn.encode(self) }
}

extension DeliveryRequest {
  public var stopTurn: PiTurnTarget? {
    guard mode == .known(.stopTurn) else { return nil }
    return JSONColumn.decode(PiTurnTarget.self, from: content)
  }
}
