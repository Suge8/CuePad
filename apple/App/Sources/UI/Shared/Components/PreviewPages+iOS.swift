#if os(iOS)
import AVKit
import CueStore
import PDFKit
import QuickLook
import SwiftUI

// 全屏预览里每类页都由 CuePad 自己画（手机）。不嵌快速查看：它把内容放在另一个进程里画，触摸进不来这边，嵌着它的页左右滑翻不了页、
// 下拉收不起。文稿、表格、演示文稿交给 WebKit（`PreviewWeb`），3D 与认不出的类型是一张静态的图（`PreviewStill`）。
// 每页铺满整屏：会滚的（图、PDF、文本、网页）铺到两条栏后面、按 `previewInsets` 让出内容边，其余排在两条栏之间（全屏页给的安全区）。

struct PreviewPage: View {
    let preview: PiPreview
    let file: URL
    let active: Bool
    @Environment(\.previewLook) private var look

    var body: some View {
        switch preview.kind {
        case .image: PreviewImage(file: file, look: look).ignoresSafeArea()
            .accessibilityElement().accessibilityLabel(Text(verbatim: preview.title)).accessibilityAddTraits(.isImage)
        case .pdf: PreviewPDF(file: file).ignoresSafeArea()
        case .video, .audio: PreviewPlayer(file: file, active: active, look: look)
        case .text: PreviewText(file: file).ignoresSafeArea()
        case .document, .spreadsheet, .presentation: PreviewWeb(file: file)
        case .model, .web, .markdown, .diff, nil: PreviewStill(preview: preview, file: file)
        }
    }
}

struct PreviewPDF: UIViewRepresentable {
    let file: URL
    /// 页与页之间那道缝（系统 PDF 视图的页距，按页的四边给）：同"预览"连续翻页时的页距，是 PDF 的版面、不随界面的间距档。
    private static let pageGaps = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    @Environment(\.palette) private var palette
    @Environment(\.previewInsets) private var insets
    @Environment(\.previewFinds) private var finds

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.isFindInteractionEnabled = true
        finds?.register(file, view.findInteraction)
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = Self.pageGaps
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

struct PreviewPlayer: UIViewControllerRepresentable {
    let file: URL
    let active: Bool
    let look: PreviewLook?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: file)
        controller.view.backgroundColor = .clear
        let cover = PreviewCover(look: look)
        cover.frame = controller.contentOverlayView?.bounds ?? .zero
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.contentOverlayView?.addSubview(cover)
        context.coordinator.ready = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak cover] _, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated { cover?.removeFromSuperview() }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if active { controller.player?.play() } else { controller.player?.pause() }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) { controller.player?.pause() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var ready: NSKeyValueObservation?
    }
}

struct PreviewCoverView: UIViewRepresentable {
    @Environment(\.previewLook) private var look
    func makeUIView(context: Context) -> PreviewCover { PreviewCover(look: look) }
    func updateUIView(_ view: PreviewCover, context: Context) {}
}

final class PreviewCover: UIView {
    private let imageView = UIImageView()
    private var aspect: CGFloat?

    init(look: PreviewLook?, ground: UIColor = .clear) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = ground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        if let now = look?.now { show(now) } else if let look {
            Task { [weak self] in if let look = await look.load() { self?.show(look) } }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ look: PreviewSources.Look) {
        imageView.image = UIImage(cgImage: look.image)
        aspect = look.aspect
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let aspect, aspect > 0, !bounds.isEmpty else { return }
        let size = bounds.width / bounds.height > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height) : CGSize(width: bounds.width, height: bounds.width / aspect)
        imageView.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

extension UIScrollView {
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

/// 3D 要转着看时点"转动查看"，进系统的快速查看（拖动在那里是转模型），不让同一个拖动既转模型又翻页。
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
        VStack(spacing: Spacing.block) {
            Group {
                if let image = look?.image {
                    Image(decorative: image, scale: scale).resizable().scaledToFit()
                } else {
                    Image(.file).font(Glyph.hero).foregroundStyle(palette.ink3)
                }
            }
            .frame(maxWidth: 360, maxHeight: 360)
            Text(preview.name).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2).multilineTextAlignment(.center)
            if preview.kind == .model {
                Button("转动查看", icon: .inspect3D) { inspecting = file }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .compact))
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) {
            look = await DeliverableLooks.load(
                preview, file: file, box: LookBox(width: Int(Self.side * scale), height: Int(Self.side * scale), fills: false), scale: scale,
                caches: services.store.files.caches)
        }
        .quickLookPreview($inspecting)
    }
}

struct PreviewText: UIViewRepresentable {
    let file: URL
    @Environment(\.previewInsets) private var insets

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .clear
        view.font = Typography.codeUIFont
        view.textContainerInset = UIEdgeInsets(top: Spacing.block, left: Spacing.group, bottom: Spacing.block, right: Spacing.group)
        Task { view.text = await Self.read(file) }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) { view.previewInsets(insets) }

    @concurrent private static func read(_ file: URL) async -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
}

@MainActor final class PreviewFinds {
    private struct Weak { weak var value: UIFindInteraction? }
    private var finds: [URL: Weak] = [:]

    func register(_ file: URL, _ find: UIFindInteraction?) { finds[file] = Weak(value: find) }

    func present(_ file: URL) { finds[file]?.value?.presentFindNavigator(showingReplace: false) }

    func dismiss() { finds.values.forEach { $0.value?.dismissFindNavigator() } }
}

extension EnvironmentValues {
    @Entry var previewFinds: PreviewFinds?
}
#endif
