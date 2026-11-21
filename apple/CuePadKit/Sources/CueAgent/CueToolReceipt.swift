import Foundation

public struct CueToolReceipt: Sendable {
  public enum Kind: String, Sendable { case request = "请求", reply = "回复" }
  public let kind: Kind
  public let id: UUID

  init(_ kind: Kind, _ id: UUID) { self.kind = kind; self.id = id }

  var mark: String { "[\(kind.rawValue) \(id.uuidString.lowercased())]" }

  public init?(result: String) {
    guard let match = result.firstMatch(of: /\[(请求|回复) ([0-9a-f-]{36})\]$/),
          let kind = Kind(rawValue: String(match.1)), let id = UUID(uuidString: String(match.2)) else { return nil }
    self.init(kind, id)
  }
}
