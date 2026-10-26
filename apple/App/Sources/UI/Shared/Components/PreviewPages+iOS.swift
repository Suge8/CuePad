#if os(iOS)
import AVKit
import CueStore
import PDFKit
import QuickLook
import SwiftUI

// 全屏预览里每类页都由 CuePad 自己画（手机）。不嵌快速查看：它把内容放在另一个进程里画，触摸进不来这边，嵌着它的页左右滑翻不了页、
// 下拉收不起。文稿、表格、演示文稿交给 WebKit（`PreviewWeb`），3D 与认不出的类型是一张静态的图（`PreviewStill`）。
// 每页铺满整屏：会滚的（图、PDF、文本、网页）铺到两条栏后面、按 `previewInsets` 让出内容边，其余排在两条栏之间（全屏页给的安全区）。

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
        case .text: PreviewText(file: file).ignoresSafeArea()
        case .document, .spreadsheet, .presentation: PreviewWeb(file: file)
        case .model, .web, .markdown, nil: PreviewStill(preview: preview, file: file)
        }
    }
}

/// PDF：系统的 PDF 视图，按宽铺满、竖着连续滚，页与页之间留一道缝，双指缩放（以手指处为锚、放大了拖到边再拖是翻页，同图片）。
struct PreviewPDF: UIViewRepresentable {
    let file: URL
    @Environment(\.palette) private var palette
    @Environment(\.previewInsets) private var insets

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        view.backgroundColor = UIColor(palette.desk)
        view.document = PDFDocument(url: file)
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != file { view.document = PDFDocument(url: file) }
        view.subviews.lazy.compactMap { $0 as? UIScrollView }.first?.previewInsets(insets)
    }
}

/// 视频与音频：系统播放器（播放、拖进度、静音、画中画都是它的），排在两条栏之间、画面外透出桌面，翻到就播（同快速查看），翻走停下。
struct PreviewPlayer: UIViewControllerRepresentable {
    let file: URL
    let active: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: file)
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if active { controller.player?.play() } else { controller.player?.pause() }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player?.pause() }
}

extension UIScrollView {
    /// 全屏页里会滚的页：铺到两条栏后面，内容边让出栏（`previewInsets`），栏后面不垫系统的滚动边缘效果（docs/ui.md「沉浸式的栏」）。
    func previewInsets(_ insets: EdgeInsets) {
        let edges = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
        guard contentInset != edges else { return }
        contentInsetAdjustmentBehavior = .never
        let atTop = contentOffset.y <= -contentInset.top
        contentInset = edges
        verticalScrollIndicatorInsets = edges
        if atTop { contentOffset.y = -edges.top }
    }
}

/// 3D 与这台设备认不出的类型：一张系统缩略图与文件名，分页与下拉照常。3D 要转着看时点"转动查看"，进系统的快速查看
/// （拖动在那里是转模型），不让同一个拖动既转模型又翻页。
struct PreviewStill: View {
    let preview: PiPreview
    let file: URL
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var scale
    @State private var look: DeliverableLook?
    @State private var inspecting: URL?

    private static let side: CGFloat = 600

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let image = look?.image {
                    Image(decorative: image, scale: scale).resizable().scaledToFit()
                } else {
                    Image(.file).font(.system(size: 56)).foregroundStyle(palette.ink3)
                }
            }
            .frame(maxWidth: 360, maxHeight: 360)
            Text(preview.name).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2).multilineTextAlignment(.center)
            if preview.kind == .model {
                Button("转动查看", icon: .inspect3D) { inspecting = file }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) {
            look = await DeliverableLooks.load(
                preview, file: file, box: LookBox(width: Int(Self.side * scale), height: Int(Self.side * scale), fills: false), scale: scale,
                caches: services.store.files.caches)
        }
        .quickLookPreview($inspecting)
    }
}

/// 文本（源代码、日志）：只读的系统文字视图，长文也只排看得见的那段。
struct PreviewText: UIViewRepresentable {
    let file: URL
    @Environment(\.previewInsets) private var insets

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        Task { view.text = await Self.read(file) }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) { view.previewInsets(insets) }

    @concurrent private static func read(_ file: URL) async -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
}
#endif
