#if DEBUG
import Foundation
import WebKit

extension DebugScene {
    /// `-CuePadWebSnapshot <PNG 路径>`：预览网页载入完后，把 WebKit 自己渲染的快照存成 PNG。后台窗口的截图里网页会变成空白
    /// （同一次运行里先有内容、几秒后空白，快照一直有内容），看网页预览渲染得对不对用这张快照，不抢前台。
    static func snapshotWeb(_ page: WebPage) {
        guard let path = defaults.string(forKey: "CuePadWebSnapshot") else { return }
        Task {
            _ = try? await page.callJavaScript("""
                await new Promise(done => document.readyState === 'complete' ? done() : addEventListener('load', done))
                """)
            guard let data = try? await page.exported(as: .image()) else { return }
            try? data.write(to: URL(filePath: path))
        }
    }
}
#endif
