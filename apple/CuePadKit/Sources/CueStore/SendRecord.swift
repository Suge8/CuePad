import Foundation

public enum SendTargetKind: String, Sendable, CaseIterable {
  case piSession
  case mac = "app"
}

public struct SendRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var targetKind: Open<SendTargetKind>
  public var targetName: String
  public var targetRef: String?
  public var cardID: UUID?
  public var sentAt: Date
  public var modifiedAt: Date
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

extension SendRecord: Record, SyncedColumns {
  static let table = Table.sendRecords
  static let fields: [Field] = [
    .plain("id"), .encrypted("content"), .plain("targetKind"), .encrypted("targetName"), .encrypted("targetRef"), .plain("cardID"),
    .plain("sentAt"), .plain("modifiedAt"), .plain("deliveryID"), .plain("origin"),
  ]
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
