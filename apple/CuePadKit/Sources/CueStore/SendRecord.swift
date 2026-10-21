import Foundation

/// 投送请求与发送记录的目标种类。发出去的只有一种：发给 Agent 会话；发送记录只会是它。
public enum SendTargetKind: String, Sendable, CaseIterable {
  case piSession
  /// 那台 Mac 上的 CuePad 本身：绑定文件夹、连接测试这类不发给会话的请求（执行器不看目标）。存储与同步的字面值沿用 "app"。
  case mac = "app"
}

public struct SendRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 发送时的内容快照；卡片之后改动或删除都不影响。
  public var content: String
  public var targetKind: Open<SendTargetKind>
  public var targetName: String
  /// Pi 会话 id 或应用 bundle id。
  public var targetRef: String?
  public var cardID: UUID?
  public var sentAt: Date
  public var modifiedAt: Date
  /// 送出它的投送请求（消息的 `PiChatMessage.deliveryID` 与它对上）与请求的来源：请求完成后会被清理，这两项留下来。
  public var deliveryID: UUID?
  public var origin: Open<DeliveryOrigin>?
}

public struct SendTarget: Equatable, Sendable {
  public var kind: Open<SendTargetKind>
  public var name: String
  public var ref: String?

  public init(kind: Open<SendTargetKind>, name: String, ref: String? = nil) {
    self.kind = kind
    self.name = name
    self.ref = ref
  }

  public init(kind: SendTargetKind, name: String, ref: String? = nil) {
    self.init(kind: .known(kind), name: name, ref: ref)
  }
}

/// 一张卡最近一次发送：何时、发给谁。
public struct LastSend: Equatable, Sendable {
  public var sentAt: Date
  public var target: SendTarget

  public init(sentAt: Date, target: SendTarget) {
    self.sentAt = sentAt
    self.target = target
  }
}

extension SendRecord: Record {
  static let table = Table.sendRecords
  static let columns = ["id", "content", "targetKind", "targetName", "targetRef", "cardID", "sentAt", "modifiedAt", "deliveryID", "origin"]
  var bindings: [any SQLBindable] {
    [id, content, targetKind.rawValue, targetName, targetRef, cardID, sentAt, modifiedAt, deliveryID, origin?.rawValue]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      targetKind: Open(rawValue: row.text(2)), targetName: row.text(3),
      targetRef: row.textOrNil(4), cardID: row.uuidOrNil(5),
      sentAt: row.date(6), modifiedAt: row.date(7),
      deliveryID: row.uuidOrNil(8), origin: row.textOrNil(9).map(Open.init(rawValue:)))
  }
}
