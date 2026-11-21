import CueText
import Foundation

extension CueStore {
  func reclaimFiles(candidates: () -> Set<String>, onFailure: (String, any Error) throws -> Void) throws -> Int {
    try write {
      var removed = 0
      for key in candidates().sorted() {
        guard try !hasAttachment(key), try !isAttachmentReferenced(key) else { continue }
        do {
          try files.remove(key)
          removed += 1
        } catch {
          try onFailure(key, error)
        }
      }
      return removed
    }
  }

  public func removeStrayFiles(drafts: [String]) throws -> Int {
    let drafted = Set(drafts.flatMap(CueFormat.attachmentKeys(in:)))
    var failed = try files.endFinishedRuns(keeping: drafted).map { "运行 \($0.run)：\($0.error)" }
    let kept = files.heldKeys().union(drafted)
    try write {
      let recorded = try db.query("SELECT hash, format FROM attachments WHERE registeredHere = 1") { AttachmentKey.make(hash: $0.text(0), format: $0.text(1)) }
      for key in Set(recorded).subtracting(kept) where try !isAttachmentReferenced(key) {
        guard let parts = AttachmentKey.parts(key) else { continue }
        try db.run("DELETE FROM attachments WHERE hash = ? AND format = ? AND registeredHere = 1", [parts.hash, parts.format])
      }
    }
    let removed = try reclaimFiles(candidates: files.unheldKeys) { key, error in failed.append("附件 \(key)：\(error)") }
    guard failed.isEmpty else { throw CueStoreError.strayFilesNotRemoved(removed: removed, failed: failed) }
    return removed
  }
}
