#if os(iOS)
import AVKit
import CueEditor
import CueStore
import PDFKit
import QuickLook
import SwiftUI

// 全屏预览里每类页都由 CuePad 自己画（手机）。不嵌快速查看：它把内容放在另一个进程里画，触摸进不来这边，嵌着它的页左右滑翻不了页、
// 下拉收不起。文稿、表格、演示文稿交给 WebKit（`PreviewWeb`），3D 与认不出的类型是一张静态的图（`PreviewStill`）。

/// 全屏页里除网页与 Markdown 外的每一类（`PreviewContent`）。
struct PreviewPage: View {
    let preview: PiPreview
    let file: URL
    let active: Bool

    var body: some View {
        switch preview.kind {
        case .image: PreviewImage(file: file)
        case .pdf: PreviewPDF(file: file)
        case .video, .audio: PreviewPlayer(file: file, active: active)
        case .text: PreviewText(file: file)
        case .document, .spreadsheet, .presentation: PreviewWeb(file: file)
        case .model, .web, .markdown, nil: PreviewStill(preview: preview, file: file)
        }
    }
}

/// 图片自己显示（不嵌快速查看，它把左右滑与下拉都吃掉）：没放大时左右滑翻页、下拉收起都给外面；双指或双击放大，放大了拖着看，双击回原样。
struct PreviewImage: View {
    let file: URL
    @Environment(\.previewZoomedIn) private var zoomedIn: Binding<Bool>
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero

    /// 解码的最长边（像素）：够全屏放大两倍看清字
    private static let maxPoints: CGFloat = 1600

    var body: some View {
        Group {
            if let image {
                let zoomed = zoom * pinch > 1
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { _ in settle(zoom * pinch) })
                    .simultaneousGesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                        drag = .zero
                    }, isEnabled: zoomed)
                    .onTapGesture(count: 2) { withAnimation(Motion.snappy) { settle(zoomed ? 1 : 2.5) } }
            } else {
                Color.clear
            }
        }
        .task(id: file) { image = await Self.decode(file, pixels: Int(Self.maxPoints * scale)) }
        // 翻走再翻回来是原样，不留着放大
        .onDisappear { settle(1) }
    }

    private func settle(_ value: CGFloat) {
        pinch = 1
        zoom = min(max(value, 1), 5)
        if zoom == 1 { offset = .zero }
        zoomedIn.wrappedValue = zoom > 1
    }

    @concurrent private static func decode(_ file: URL, pixels: Int) async -> CGImage? {
        Thumbnails.image(at: file, maxPixel: pixels)
    }
}
/// PDF：系统的 PDF 视图，按宽铺满、竖着连续滚，双指缩放。
struct PreviewPDF: UIViewRepresentable {
    let file: URL
    @Environment(\.palette) private var palette

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(palette.desk)
        view.document = PDFDocument(url: file)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != file { view.document = PDFDocument(url: file) }
    }
}

/// 视频与音频：系统播放器，翻到就播（同快速查看），翻走停下。
struct PreviewPlayer: View {
    let file: URL
    let active: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onChange(of: active, initial: true) { _, active in
                if active {
                    if player == nil { player = AVPlayer(url: file) }
                    player?.play()
                } else {
                    player?.pause()
                }
            }
            .onDisappear { player?.pause() }
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

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        Task { view.text = await Self.read(file) }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}

    @concurrent private static func read(_ file: URL) async -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
}
#endif
