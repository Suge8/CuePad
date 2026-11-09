import Foundation

extension CueStore {
  /// 记录删除提交后才能进入；持写锁核对记录与所有引用，直到文件删除结束，别的连接不能在中间重新引用。
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
}
