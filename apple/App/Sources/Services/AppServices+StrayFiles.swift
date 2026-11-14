import CueStore
import Foundation

extension AppServices {
    /// 草稿文字里的引用（跨启动留着的）也算引用。
    func startStrayFileCleanup() {
        let drafts = settings.draftTexts
        // 旧版的实时活动取证目录：取证已并进诊断存档（`DiagnosticArchive.activity`）
        try? FileManager.default.removeItem(at: location.directory.appending(path: "ActivityDiagnostics", directoryHint: .isDirectory))
        follow { [store] in
            do {
                let removed = try await store.removeStrayFiles(drafts: drafts)
                if removed > 0 { Self.log.notice("清掉了 \(removed, privacy: .public) 个没用上的附件文件") }
            } catch {
                Self.log.error("没用上的附件文件没能清掉：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
