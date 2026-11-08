import Foundation

extension CueStore {
  /// 只重新唤醒尚未交给 Cue 的原记录；不删除、不复制正文、不换 UUID。
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

  /// 尚未落库的原语音请求只保存在 Mac 通话 owner；客户端不能提供正文，只能再次指名原对象。
  public func recordVoiceRequest(_ text: String, command: UUID, host: String) throws -> CueMessage {
    try write {
      guard try cueProfile()?.activeHost == host else { throw CueStoreError.deliveryAlreadyHanded }
      if let existing = try find(CueMessage.self, command) {
        guard existing.author == .known(.you), existing.text == text else { throw CueStoreError.deliveryAlreadyHanded }
        return existing
      }
      return try addCueMessage(.you, text: text, id: command)
    }
  }
}
