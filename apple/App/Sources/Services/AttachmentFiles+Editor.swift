import CueEditor
import CueStore

/// 编辑器直接读写附件目录：同步调用、不经 Store actor；附件记录在引用它的正文保存时登记。
extension AttachmentFiles: @retroactive CueFileStore {}
