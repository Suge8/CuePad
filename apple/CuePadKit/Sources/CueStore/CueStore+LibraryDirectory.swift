import Foundation

extension CueStore {
  /// 资料库目录（`LibraryLocation.directory`）：库旁不同步的本机文件（如 Cue 的大脑健康）放在这里。
  /// 从附件的保底目录（库旁的 `Attachments/`）推出，不另存第二份位置。
  public nonisolated var libraryDirectory: URL { files.backups.deletingLastPathComponent() }
}
