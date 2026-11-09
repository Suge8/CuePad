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
  /// 剩下的边界同永久删除（`reclaimAttachments`，按键删这个键的所有记录）：同一份内容这台与别的设备各登记过、别的设备的卡片还没到时，
  /// 收这台的记录会连同那台的一起删。与只看"有没有引用"时的窗口不同，它要两台恰好存过同一份内容、这台又已不再引用，不是每张别处来的图都会撞上。
  /// 某个运行目录或文件删不掉不挡别的：都清过一遍后，连同删掉的个数一起抛 `strayFilesNotRemoved`。
  public func removeStrayFiles(drafts: [String]) throws -> Int {
    let drafted = Set(drafts.flatMap(CueFormat.attachmentKeys(in:)))
    var failed = try files.endFinishedRuns(keeping: drafted).map { "运行 \($0.run)：\($0.error)" }
    let kept = files.heldKeys().union(drafted)
    try write {
      let recorded = try db.query("SELECT hash, format FROM attachments WHERE registeredHere = 1") { AttachmentKey.make(hash: $0.text(0), format: $0.text(1)) }
      _ = try reclaimAttachments(Set(recorded).subtracting(kept))
    }
    let removed = try reclaimFiles(candidates: files.unheldKeys) { key, error in failed.append("附件 \(key)：\(error)") }
    guard failed.isEmpty else { throw CueStoreError.strayFilesNotRemoved(removed: removed, failed: failed) }
    return removed
  }
}
