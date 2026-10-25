#if os(macOS)
import AVKit
import CueEditor
import CueStore
import PDFKit
import Quartz
import SwiftUI

// 全屏预览里每类页怎么显示（Mac）。图片、PDF、音视频用系统的视图自己显示：嵌快速查看时它的图片只有捏合缩放，没有双击放大、拖着看，
// 也不把滑到头的横扫交给翻页；PDF 与音视频在 PDFKit、AVKit 里是同样的系统视图，能直接设内容让到两条栏之间的边。
// 文本、文稿、表格、演示文稿、3D 与认不出的类型仍嵌快速查看：这些系统才认得全，也没有要和翻页抢的手势。
// 图片与 PDF 一直铺到两条栏下面（放大、滚动时内容从栏后透出来），按 `previewChrome` 让出栏占的边；其余在两条栏之间。

extension EnvironmentValues {
    /// 全屏页顶栏与底栏占的边（`PreviewPager`）。
    @Entry var previewChrome = EdgeInsets()
}

/// 全屏页里除网页与 Markdown 外的每一类（`PreviewContent`）。
struct PreviewPage: View {
    let preview: PiPreview
    let file: URL
    let active: Bool

    var body: some View {
        switch preview.kind {
        case .image: PreviewImage(file: file).ignoresSafeArea()
        case .pdf: PreviewPDF(file: file).ignoresSafeArea()
        case .video, .audio: PreviewPlayer(file: file, active: active)
        default: QuickLookPage(file: file)
        }
    }
}

/// 图片：`PreviewZoom`。
private struct PreviewImage: NSViewRepresentable {
    let file: URL
    @Environment(\.previewChrome) private var chrome

    func makeNSView(context: Context) -> PreviewZoom { PreviewZoom(file: file) }

    func updateNSView(_ view: PreviewZoom, context: Context) {
        view.chrome = NSEdgeInsets(top: chrome.top, left: chrome.leading, bottom: chrome.bottom, right: chrome.trailing)
    }
}

/// PDF：系统的 PDF 视图，按宽铺满、竖着连续滚，捏合与智能缩放是它自己的。
private struct PreviewPDF: NSViewRepresentable {
    let file: URL
    @Environment(\.palette) private var palette
    @Environment(\.previewChrome) private var chrome

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(palette.desk)
        view.document = PDFDocument(url: file)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        let insets = NSEdgeInsets(top: chrome.top, left: 0, bottom: chrome.bottom, right: 0)
        guard scroll.contentInsets.top != insets.top || scroll.contentInsets.bottom != insets.bottom else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = insets
    }
}

/// 视频与音频：系统播放器（控件浮在画面上，指针移上去才出现），翻到就播（同快速查看），翻走、关上停下；
/// 翻到时它接键盘（`Player`），空格暂停、继续是它自己的（←→ 归翻页，`PageInput`）。
private struct PreviewPlayer: NSViewRepresentable {
    let file: URL
    let active: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = Player()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: file)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if active { view.player?.play() } else { view.player?.pause() }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }

    /// 进了窗口就接键盘；回复栏正打着字时不抢。
    private final class Player: AVPlayerView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// 嵌在页里的快速查看。拆掉时关掉它。
private struct QuickLookPage: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.previewItem = file as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
#endif
