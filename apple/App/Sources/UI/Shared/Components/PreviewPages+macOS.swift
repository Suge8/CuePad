#if os(macOS)
import CueStore
import Quartz
import SwiftUI

/// 全屏页里除网页与 Markdown 外的每一类（`PreviewContent`）：嵌系统的快速查看（缩放、播放、翻页都有；Mac 上它不抢翻页的手势）。
struct PreviewPage: View {
    let preview: PiPreview
    let file: URL
    let active: Bool

    var body: some View { QuickLookPage(file: file) }
}

/// 嵌在页里的快速查看。音视频翻到就播（同系统的快速查看面板；视频的播放控件要指针移上去才出现）；拆掉时关掉它，正在播的随之停下。
private struct QuickLookPage: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        view.previewItem = file as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != file { view.previewItem = file as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
#endif
