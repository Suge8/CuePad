import CueStore
import Foundation

extension AppServices {
    /// 启动时清一次存进来却没用上的附件文件与上次运行留下的持有（`CueStore.removeStrayFiles`）；跨启动的草稿文字里的引用算引用。
    func startStrayFileCleanup() {
        let drafts = settings.draftTexts
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
