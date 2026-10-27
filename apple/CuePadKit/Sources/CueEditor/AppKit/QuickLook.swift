#if canImport(AppKit)
import AppKit
import QuickLookUI

/// 系统的快速查看面板看一个附件：本机那份的文件名是键（哈希），标题另给（正文里的文件名）。面板只有一个，数据源就是这里。
@MainActor
public final class QuickLook: NSObject, QLPreviewPanelDataSource {
    private static let shared = QuickLook()
    private var item: Item?

    public static func show(_ url: URL, title: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        shared.item = Item(url: url, title: title)
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { Self.shared.item }
    }

    // 只有两个不变的值
    private final class Item: NSObject, QLPreviewItem, @unchecked Sendable {
        let url: URL
        let title: String
        init(url: URL, title: String) {
            self.url = url
            self.title = title
        }
        var previewItemURL: URL! { url }
        var previewItemTitle: String! { title }
    }
}
#endif
