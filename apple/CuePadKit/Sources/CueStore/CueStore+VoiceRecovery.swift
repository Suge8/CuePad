import Foundation

extension CueStore {
  public func recoverCueMessage(_ original: UUID, host: String) throws -> CueMessage {
    try write {
      guard try cueProfile()?.activeHost == host else { throw CueStoreError.deliveryAlreadyHanded }
      guard let message = try find(CueMessage.self, original), message.author == .known(.you) else { throw CueStoreError.notFound }
      guard message.deliveredAt == nil else { throw CueStoreError.deliveryAlreadyHanded }
      try db.run("UPDATE cueMessages SET modifiedAt = ? WHERE id = ?", [Date.stamp, original])
      guard let updated = try find(CueMessage.self, original) else { throw CueStoreError.notFound }
      return updated
    }
  }

  public func recordVoiceRequest(_ text: String, command: UUID, host: String?) throws -> CueMessage {
    try write {
      guard let activeHost = try cueProfile()?.activeHost, host == nil || activeHost == host else { throw CueStoreError.deliveryAlreadyHanded }
      if let existing = try find(CueMessage.self, command) {
        guard existing.author == .known(.you), existing.text == text else { throw CueStoreError.deliveryAlreadyHanded }
        return existing
      }
      return try putCueMessage(.you, text: text, id: command)
    }
  }
}
