import Foundation

extension CueStore {
  public func cards(idPrefix prefix: String) throws -> [Card] {
    try select(Card.self, where: "id >= ?1 AND id < ?1 || '~'", [prefix.lowercased()], orderBy: "id")
  }

  public func previews(idPrefix prefix: String) throws -> [PreviewItem] {
    try select(PreviewItem.self, where: "id >= ?1 AND id < ?1 || '~'", [prefix.lowercased()], orderBy: "id")
  }
}
