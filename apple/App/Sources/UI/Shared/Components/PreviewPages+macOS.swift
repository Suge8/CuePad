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

struct PreviewPage: View {
    let preview: PiPreview
    let file: URL
    let active: Bool

    var body: some View {
        switch preview.kind {
        case .image: PreviewImage(preview: preview.id, file: file).ignoresSafeArea()
            .accessibilityElement().accessibilityLabel(Text(verbatim: preview.title)).accessibilityAddTraits(.isImage)
        case .pdf: PreviewPDF(preview: preview.id, file: file).ignoresSafeArea()
        case .video, .audio: PreviewPlayer(file: file, active: active)
        default: QuickLookPage(file: file)
        }
    }
}

private struct PreviewImage: NSViewRepresentable {
    let preview: UUID
    let file: URL
    @Environment(\.previewInsets) private var chrome
    @Environment(\.previewFlight) private var flight

    func makeNSView(context: Context) -> PreviewZoom { PreviewZoom(file: file) }

    func updateNSView(_ view: PreviewZoom, context: Context) {
        view.chrome = NSEdgeInsets(top: chrome.top, left: chrome.leading, bottom: chrome.bottom, right: chrome.trailing)
        flight?.showing(preview, view)
    }
}

private struct PreviewPDF: NSViewRepresentable {
    let preview: UUID
    let file: URL
    @Environment(\.palette) private var palette
    @Environment(\.previewInsets) private var chrome
    @Environment(\.previewFlight) private var flight

    func makeCoordinator() -> Shown { Shown() }

    func makeNSView(context: Context) -> PDFFindHost {
        let host = PDFFindHost(document: PDFDocument(url: file))
        host.pdf.autoScales = true
        host.pdf.displayMode = .singlePageContinuous
        host.pdf.backgroundColor = NSColor(palette.desk)
        context.coordinator.view = host.pdf
        return host
    }

    func updateNSView(_ host: PDFFindHost, context: Context) {
        flight?.showing(preview, context.coordinator)
        host.top = chrome.top
        host.chrome = NSEdgeInsets(top: chrome.top, left: 0, bottom: chrome.bottom, right: 0)
    }
}

extension PreviewPDF {
    final class Shown: PreviewShowing {
        weak var view: PDFView?

        /// 不用视图截图（`cacheDisplay`）：PDF 视图的页是分块图层，截出来是白的。
        func shown(in window: NSWindow) -> PreviewShown {
            guard let view, let scroll = view.documentView?.enclosingScrollView else { return .opened }
            let pages = view.visiblePages.map { ($0, view.convert(view.convert($0.bounds(for: view.displayBox), from: $0), to: nil)) }
            let region = pages.reduce(CGRect.null) { $0.union($1.1) }.intersection(scroll.convert(scroll.bounds, to: nil))
            guard !region.isEmpty, let image = Self.draw(pages, in: region, box: view.displayBox, desk: view.backgroundColor, scale: window.backingScaleFactor)
            else { return .opened }
            return .picture(image, PreviewFrame(rect: region))
        }

        private static func draw(_ pages: [(PDFPage, CGRect)], in region: CGRect, box: PDFDisplayBox, desk: NSColor, scale: CGFloat) -> CGImage? {
            guard let context = CGContext(
                data: nil, width: Int(region.width * scale), height: Int(region.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            context.setFillColor(desk.cgColor)
            context.fill(region)
            for (page, rect) in pages {
                let bounds = page.bounds(for: box)
                context.saveGState()
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(rect)
                context.translateBy(x: rect.minX, y: rect.minY)
                context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
                page.draw(with: box, to: context)
                context.restoreGState()
            }
            return context.makeImage()
        }
    }
}

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

    private final class Player: AVPlayerView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(self)
        }
    }
}

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
