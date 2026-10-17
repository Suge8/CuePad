import CueEditor
import CueStore
#if os(macOS)
import Quartz
#else
import QuickLook
#endif
import SwiftUI

/// 点开的那一份，和与它同一组的几份（全屏页里左右翻）；`group` 认它从哪张缩略图放大（`PreviewZoomKey`），`reply` 是底栏对谁说。
struct PreviewOpening: Identifiable, Equatable {
    let preview: PiPreview
    let batch: [PiPreview]
    let group: String
    let reply: PreviewReply

    var id: UUID { preview.id }
}

/// 全屏页底栏：从结果卡打开是对 Cue 说，从会话页打开是对这个会话说，从"等你"打开是那几个选项。
enum PreviewReply: Equatable {
    case cue
    case session(PiSessionState)
    /// `question` 是"等你"卡上那句要你定什么（`CueAsk.question`）
    case answer(CueMessage, question: String)
}

extension View {
    /// 点交付物后的全屏页：同一组的几份左右翻；网页与 Markdown 由 CuePad 自己显示（网页只读、不联网），其余嵌系统的快速查看（缩放、播放、翻页都有）。
    /// 手机上从点的那张缩略图放大出来（系统 zoom 转场），下滑缩回翻到的那一份原处；减弱动态效果时整块交叉淡入淡出。Mac 是窗口内浮层。
    /// 一个页面只在这里挂一次，不在每张缩略图上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>) -> some View { modifier(PreviewPresenter(opened: opened)) }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    /// 呈现着的那一份：跟着 `opened` 走，只多管一件事——减弱动态效果时不带呈现动画地换上（不滑上来，全屏页自己淡入，`PreviewPager.shown`）。
    /// 调用处直接写 `opened`，写的那一下的动画由它们定，这里另起一个事务才拦得住。
    @State private var presented: PreviewOpening?
    @Namespace private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .environment(\.previewZoom, reduceMotion ? nil : zoom)
            #endif
            .onChange(of: opened, initial: true) { _, next in
                var transaction = Transaction()
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction) { presented = next }
            }
            .panel(item: Binding { presented } set: { presented = $0; opened = $0 }, style: .fullScreen) {
                PreviewPager(opening: $0, current: $0.preview.id, zoom: reduceMotion ? nil : zoom)
                    #if os(macOS)
                    .frame(maxWidth: 960, maxHeight: 760)
                    .background(palette.desk)
                    #endif
            }
    }
}

/// 全屏页：顶上是各端浮层统一的那一行（Mac 是 `PanelHeader`：标题居中，前后箭头、分享与关闭在右上；iOS 是系统顶栏：左关闭、中间标题与
/// "第几份 · 类型"、右分享），标题是当前这一份（写法同缩略图下那行），内容紧接着铺满，底部一条玻璃栏（`PreviewReplyBar`）。
private struct PreviewPager: View {
    let opening: PreviewOpening
    @State var current: UUID
    let zoom: Namespace.ID?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    #if os(iOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 减弱动态效果时整页的淡入淡出
    @State private var shown = false
    #endif

    private var batch: [PiPreview] { opening.batch }
    private var index: Int { batch.firstIndex { $0.id == current } ?? 0 }
    private var preview: PiPreview { batch[index] }
    private var title: String { DeliverableStrip.label(of: preview, in: batch) }
    /// "2 / 3 · 图片"，只有一份时只写类型
    private var position: Dotted { Dotted(batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil, preview.kind?.label) }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            TabView(selection: $current) {
                ForEach(batch) { PreviewContent(preview: $0, file: file(of: $0), active: $0.id == current, pulledDown: dismiss).tag($0.id) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(palette.desk)
            .navigationTitle(title)
            .navigationSubtitle(position.visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
                if let file = file(of: preview) { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) } }
            }
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 8) {
                    if batch.count > 1 { arrow(-1) }
                    PreviewReplyBar(reply: opening.reply, about: title, done: dismiss)
                    if batch.count > 1 { arrow(1) }
                }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
        }
        .zoomed(from: PreviewZoomKey(group: opening.group, preview: current), in: zoom)
        .opacity(reduceMotion && !shown ? 0 : 1)
        .presentationBackground(reduceMotion ? .clear : palette.desk)
        .onAppear { if reduceMotion { withAnimation(Motion.crossfade) { shown = true } } }
        #else
        VStack(spacing: 10) {
            PanelHeader(title: title) {
                stepper
                if let file = file(of: preview) {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up").accessibilityLabel("分享") }
                }
            }
            .buttonStyle(.borderless).foregroundStyle(palette.ink2)
            PreviewContent(preview: preview, file: file(of: preview)).id(preview.id)
            PreviewReplyBar(reply: opening.reply, about: title, done: dismiss)
                .frame(maxWidth: 640).padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 14)
        .background(palette.desk)
        #endif
    }

    #if os(iOS)
    /// 底栏两头的前后箭头：快速查看的页（PDF、视频、文稿……）自己吃掉左右滑与下滑，翻到它那页时靠它们翻、靠关闭钮收起。
    private func arrow(_ offset: Int) -> some View {
        let target = index + offset
        return Button(offset < 0 ? "上一个" : "下一个", systemImage: offset < 0 ? "chevron.left" : "chevron.right") {
            withAnimation(Motion.quick) { current = batch[target].id }
        }
        .labelStyle(.iconOnly).font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
        .frame(width: ComposerMetrics.slot, height: ComposerMetrics.slot)
        .glass(in: .circle, interactive: true)
        .disabled(!batch.indices.contains(target))
    }
    #endif

    #if os(macOS)
    /// 前后箭头夹着"第几份 · 类型"。
    @ViewBuilder private var stepper: some View {
        if batch.count > 1 { Button("上一个", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly).disabled(index == 0) }
        Text(position).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
        if batch.count > 1 { Button("下一个", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly).disabled(index == batch.count - 1) }
    }

    private func step(_ offset: Int) {
        withAnimation(Motion.quick) { current = batch[index + offset].id }
    }
    #endif

    /// 关掉：减弱动态效果时先淡出再无动画地收起，其余照系统的（手机上缩回那张缩略图）。
    private func dismiss() {
        #if os(iOS)
        if reduceMotion {
            withAnimation(Motion.crossfade) { shown = false } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { close() }
            }
            return
        }
        #endif
        close()
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.url(of: preview)
    }
}

private extension View {
    @ViewBuilder func zoomed(from key: PreviewZoomKey, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace { navigationTransition(.zoom(sourceID: key, in: namespace)) } else { self }
        #else
        self
        #endif
    }
}

/// 一个文件的内容：网页、Markdown 自己显示，其余嵌快速查看。
private struct PreviewContent: View {
    let preview: PiPreview
    let file: URL?
    /// 是不是翻到的这一页（翻页留着的邻页不是）
    var active = true
    /// 图片页下拉到底：收起全屏页（手机）
    var pulledDown: () -> Void = {}
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let file {
                switch preview.kind {
                case .web: PreviewWeb(file: file)
                case .markdown: PreviewMarkdown(file: file)
                #if os(iOS)
                case .image: PreviewImage(file: file, pulledDown: pulledDown)
                #endif
                #if os(macOS)
                default: QuickLookPage(file: file)
                #else
                default: QuickLookPage(file: file, active: active)
                #endif
                }
            } else {
                EmptyState(mascot: .error, title: "读不了这个文件").padding(24).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
    }
}

#if os(macOS)
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
#else
/// 嵌在页里的快速查看（只放这一个文件，切换由外面的分页做）。快速查看在另一个进程里播音视频，控制器拆掉或翻走了它还接着播：
/// 不在当前页时换成空列表让它停下，翻回来再放回这个文件。
private struct QuickLookPage: UIViewControllerRepresentable {
    let file: URL
    var active = true

    func makeCoordinator() -> Source { Source() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        context.coordinator.file = active ? file : nil
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        let shown = active ? file : nil
        guard context.coordinator.file != shown else { return }
        context.coordinator.file = shown
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var file: URL?
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file! as NSURL }
    }
}
#endif

#if os(iOS)
/// 图片自己显示（不嵌快速查看）：没放大时左右滑翻页给外面，往下拉跟着手指走、拉过一截松手就缩回原处（`pulledDown`；
/// 系统 zoom 转场自带的下滑收起在翻页的分页里接不到手势）；双指或双击放大，放大了拖着看，双击回原样。
private struct PreviewImage: View {
    let file: URL
    let pulledDown: () -> Void
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    /// 没放大时往下拉了多少
    @State private var pull: CGFloat = 0

    /// 拉过这么多松手就收起
    private static let pullToClose: CGFloat = 110

    /// 解码的最长边（像素）：够全屏放大两倍看清字
    private static let maxPoints: CGFloat = 1600

    var body: some View {
        Group {
            if let image {
                let zoomed = zoom * pinch > 1
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .scaleEffect(1 - min(pull, 400) / 1600)
                    .offset(y: pull)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { _ in settle(zoom * pinch) })
                    .simultaneousGesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                        drag = .zero
                    }, isEnabled: zoomed)
                    .gesture(PullDown(enabled: !zoomed) { pull = $0 } ended: {
                        if pull > Self.pullToClose { pulledDown() } else { withAnimation(Motion.snappy) { pull = 0 } }
                    })
                    .onTapGesture(count: 2) { withAnimation(Motion.snappy) { settle(zoomed ? 1 : 2.5) } }
            } else {
                Color.clear
            }
        }
        .task(id: file) { image = await Self.decode(file, pixels: Int(Self.maxPoints * scale)) }
    }

    private func settle(_ value: CGFloat) {
        pinch = 1
        zoom = min(max(value, 1), 5)
        if zoom == 1 { offset = .zero }
    }

    @concurrent private static func decode(_ file: URL, pixels: Int) async -> CGImage? {
        Thumbnails.image(at: file, maxPixel: pixels)
    }
}
/// 往下拉（手机图片页）：UIKit 的拖动手势，一开始就判方向——横着的当场放弃、交给外面的翻页，SwiftUI 的拖动手势会把翻页的滑动一起吃掉。
private struct PullDown: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) { pan.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .changed: changed(max(pan.translation(in: pan.view).y, 0))
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

private struct PreviewMarkdown: View {
    let file: URL
    @State private var text: String?
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            MarkdownText(source: text ?? "").padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
}
