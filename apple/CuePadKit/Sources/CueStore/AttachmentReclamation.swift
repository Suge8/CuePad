import CueText
import Foundation

extension CueStore {
  /// 记录删除提交后才能进入；持写锁核对记录与所有引用，直到文件删除结束，别的连接不能在中间重新引用。
  /// 只删缓存与保底，持有（`AttachmentRun`）不碰：已存好、还没提交引用的写者提交时由它补回。
  /// 事务只读，文件删除失败不涉及数据库回滚；调用方决定逐键报告还是遇错即停。
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

  /// App 启动时清一次，返回删了几个文件：结束了的运行留下的持有删掉，`drafts`（跨启动留着的草稿，库里看不到）引用的键先挪进这次运行；
  /// 再收没有哪个运行持有、草稿与库里都没人引用（`isAttachmentReferenced`）的：没记录的删缓存与保底（存进来却没发出去的、编辑器里插了又删的、
  /// 回收时没删成的）；这台设备登记的记录（`registeredHere`）连记录一起删（编辑时删掉了图、再永久删卡：永久删除只看卡片当时正文里的键）。
  /// 别处来的记录不收：同步乱序，记录可能先于引用它的卡片到，这时没人引用不等于没人用，删了还会把删除同步出去、别的设备上的图找不回来。
  /// 升级（95）前就有的记录也算别处来的，漏下的照旧留着。
  /// 只删这台登记的那几行，不按键删这份内容的全部记录（永久删除 `reclaimAttachments` 按键删：那是用户明确要删这张卡，这里只是回收本机的垃圾）：
  /// 同一份内容别的设备也登记过时，它那条与本机文件都留着（文件回收看到还有记录就不删），每台只回收自己登记的；
  /// 别的设备引用这份内容时登记了它自己的一条（`registerAttachment`），这里删掉自己那条不会让那边的引用没了记录；
  /// 例外是那台引用时本机没有文件、登记不了自己那条：它的卡片传过来之前这里清理，那边的引用就没有文件了（有意接受的边界，见 `registerAttachment`）。
  /// 某个运行目录或文件删不掉不挡别的：都清过一遍后，连同删掉的个数一起抛 `strayFilesNotRemoved`。
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
