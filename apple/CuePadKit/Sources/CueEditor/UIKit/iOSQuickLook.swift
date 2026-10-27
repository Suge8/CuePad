#if canImport(UIKit)
import QuickLook
import UIKit

/// 系统的快速查看看一个附件：本机那份的文件名是键（哈希），标题另给（正文里的文件名）。从 `view` 所在的最上层页面弹出。
@MainActor
public enum QuickLook {
    public static func show(_ url: URL, title: String, from view: UIView) {
        guard var top = view.window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(Controller(item: Item(url: url, title: title)), animated: true)
    }

    /// 自己当自己的数据源（数据源是弱引用，跟着页面活）。
    private final class Controller: QLPreviewController, QLPreviewControllerDataSource {
        let item: Item

        init(item: Item) {
            self.item = item
            super.init(nibName: nil, bundle: nil)
            dataSource = self
        }

        required init?(coder: NSCoder) { nil }

        nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            MainActor.assumeIsolated { item }
        }
    }

    // 只有两个不变的值
    private final class Item: NSObject, QLPreviewItem, @unchecked Sendable {
        let url: URL
        let title: String
        init(url: URL, title: String) {
            self.url = url
            self.title = title
        }
        var previewItemURL: URL? { url }
        var previewItemTitle: String? { title }
    }
}
#endif
