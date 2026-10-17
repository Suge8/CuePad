#if DEBUG
import Foundation
import WebKit

extension DebugScene {
    /// `-CuePadWebSnapshot <PNG 路径>`：预览网页打开时，用同一套拦截规则另载入一份、载入完把 WebKit 自己渲染的快照存成 PNG。
    /// 后台窗口的截图里网页会变成空白（同一次运行里先有内容、几秒后空白，快照一直有内容），看网页预览渲染得对不对用这张快照，不抢前台。
    static func snapshotWeb(_ file: URL) {
        guard let path = defaults.string(forKey: "CuePadWebSnapshot") else { return }
        Task {
            guard let page = try? await PreviewWebGuard.page(for: file),
                let data = try? await page.exported(as: .image())
            else { return }
            try? data.write(to: URL(filePath: path))
        }
    }
}
#endif
