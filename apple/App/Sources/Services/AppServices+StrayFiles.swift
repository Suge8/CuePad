import CueStore
import Foundation

extension AppServices {
    /// 启动时清一次存进来却没用上的附件文件（`CueStore.removeStrayFiles`：回复框选了没发的、编辑器里插了又删的，它们一直留在保底里）。
    /// 只看这次启动之前存下的：这次运行里存的（输入框里的、正在入库的分享）不碰；回复框带的附件不跨启动，跨启动的草稿文字里的引用算引用。
    func startStrayFileCleanup() {
        let since = Date.now, drafts = settings.draftTexts
        follow { [store] in
            do {
                let removed = try await store.removeStrayFiles(before: since, drafts: drafts)
                if removed > 0 { Self.log.notice("清掉了 \(removed, privacy: .public) 个没用上的附件文件") }
            } catch {
                Self.log.error("没用上的附件文件没能清掉：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
