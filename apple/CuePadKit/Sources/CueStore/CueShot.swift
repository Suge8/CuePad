import Foundation

public struct CueShot: Codable, Hashable, Sendable {
  public let preview: UUID
  public let look: String

  public static let limit = 4
  public static let lookLimit = 20

  public init(preview: UUID, look: String) {
    self.preview = preview
    self.look = look
  }

  private static func phrase(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。？?！!"))
    guard !trimmed.isEmpty, trimmed.count <= lookLimit, !trimmed.contains(where: \.isNewline) else {
      throw CueStoreError.phrase(field: "show 每张要写 look", hint: "这张看什么，如“方案 1：大按钮占满一行”", limit: lookLimit)
    }
    return trimmed
  }

  public static func checked(_ shots: [CueShot]) throws -> [CueShot] {
    guard shots.count <= limit, Set(shots.map(\.preview)).count == shots.count else { throw CueStoreError.shots(limit: limit) }
    return try shots.map {
      CueShot(preview: $0.preview, look: try phrase($0.look))
    }
  }
}
