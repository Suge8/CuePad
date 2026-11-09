import Foundation

extension CueStore {
  /// 走主键索引的范围扫描（库里的 id 一律是小写文本，`~` 比 id 里任何字符都大），不读全表。
  public func cards(idPrefix prefix: String) throws -> [Card] {
    try select(Card.self, where: "id >= ?1 AND id < ?1 || '~'", [prefix.lowercased()], orderBy: "id")
  }

  public func previews(idPrefix prefix: String) throws -> [PiPreview] {
    try select(PiPreview.self, where: "id >= ?1 AND id < ?1 || '~'", [prefix.lowercased()], orderBy: "id")
  }
}
