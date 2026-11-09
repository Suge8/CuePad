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
  /// 再删缓存与保底里没有哪个运行持有、没有附件记录、库里也没人引用的（`isAttachmentReferenced`）：
  /// 存进来却没发出去的、编辑器里插了又删的、回收时没删成的。
  public func removeStrayFiles(drafts: [String]) throws -> Int {
    try files.endFinishedRuns(keeping: Set(drafts.flatMap(CueFormat.attachmentKeys(in:))))
    return try reclaimFiles(candidates: files.unheldKeys) { _, error in throw error }
  }
}
