#if DEBUG
import Foundation
import WebKit

extension DebugScene {
    /// 后台窗口的截图里网页会变成空白（同一次运行里先有内容、几秒后空白，快照一直有内容），看网页预览渲染得对不对用这张快照，不抢前台。
    static func snapshotWeb(_ file: URL) {
        guard let path = args.webSnapshot else { return }
        Task {
            await running("网页快照") {
                let page = try await PreviewWebGuard.page(for: file)
                try await page.exported(as: .image()).write(to: URL(filePath: path))
            }
        }
    }
}
#endif
