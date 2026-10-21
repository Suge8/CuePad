import CueStore
#if os(macOS)
import Quartz
#endif
import SwiftUI

/// 点开的那一份，和与它同一组的几份（全屏页里左右翻）；`group` 认它从哪张缩略图放大（`PreviewZoomKey`），`reply` 是底栏对谁说。
/// `looks`：提问点名的图各看什么（`CueShown`），有的话页顶写它，不写标题。
struct PreviewOpening: Identifiable, Equatable {
    let preview: PiPreview
    let batch: [PiPreview]
    let group: String
    let reply: PreviewReply
    var looks: [UUID: String] = [:]

    var id: UUID { preview.id }
}

/// 全屏页底栏：从结果卡打开是对 Cue 说，从会话页打开是对这个会话说，从"等你"打开是那几个选项。
enum PreviewReply: Equatable {
    case cue
    case session(PiSessionState)
    case answer(CueMessage)
}

extension View {
    /// 点交付物后的全屏页：同一组的几份左右翻；手机上每类都由 CuePad 自己显示（`PreviewPages+iOS`；网页与文稿只读、不联网），
    /// Mac 上网页与 Markdown 自己显示，其余嵌系统的快速查看（缩放、播放、翻页都有；Mac 上它不抢翻页的手势）。
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
    /// 往下拉了多少（`PageSwipe`）
    @State private var pull: CGFloat = 0
    /// 图片页放大着：拖动是看图，不是收起
    @State private var zoomedIn = false
    #endif

    private var batch: [PiPreview] { opening.batch }
    private var index: Int { batch.firstIndex { $0.id == current } ?? 0 }
    private var preview: PiPreview { batch[index] }
    private var title: String { opening.looks[preview.id] ?? preview.title }
    /// "2 / 3 · 图片"，只有一份时只写类型
    private var position: Dotted { Dotted(batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil, preview.kind?.label) }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            TabView(selection: $current) {
                ForEach(batch) { PreviewContent(preview: $0, file: file(of: $0), active: $0.id == current, zoomedIn: $zoomedIn).tag($0.id) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scaleEffect(1 - min(pull, 400) / 1600)
            .offset(y: pull)
            .gesture(PageSwipe(enabled: !zoomedIn) { pull = $0 } released: { pulled in
                if pulled > Self.pullToClose { dismiss() } else { withAnimation(Motion.snappy) { pull = 0 } }
            })
            .onChange(of: current) { zoomedIn = false }
            .background(palette.desk)
            .navigationTitle(title)
            .navigationSubtitle(position.visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { dismiss() } }
                if let file = file(of: preview) { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) } }
            }
            .safeAreaBar(edge: .bottom) {
                PreviewReplyBar(reply: opening.reply, about: title, done: dismiss)
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
                    ShareLink(item: file) { Image(.share).accessibilityLabel("分享") }
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
    /// 拉过这么多松手就收起
    private static let pullToClose: CGFloat = 110

    #endif

    #if os(macOS)
    /// 前后箭头夹着"第几份 · 类型"。
    @ViewBuilder private var stepper: some View {
        if batch.count > 1 { Button("上一个", icon: .back) { step(-1) }.labelStyle(.iconOnly).disabled(index == 0) }
        Text(position).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
        if batch.count > 1 { Button("下一个", icon: .forward) { step(1) }.labelStyle(.iconOnly).disabled(index == batch.count - 1) }
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

/// 一个文件的内容：哪类怎么显示见 `previewPresenter`。
private struct PreviewContent: View {
    let preview: PiPreview
    let file: URL?
    /// 是不是翻到的这一页（翻页留着的邻页不是）
    var active = true
    /// 图片页放大着（手机：这时拖动是看图，不收起）
    var zoomedIn: Binding<Bool> = .constant(false)
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let file {
                switch preview.kind {
                case .web: PreviewWeb(file: file)
                case .markdown: PreviewMarkdown(file: file)
                #if os(iOS)
                case .image: PreviewImage(file: file, zoomedIn: active ? zoomedIn : .constant(false))
                case .pdf: PreviewPDF(file: file)
                case .video, .audio: PreviewPlayer(file: file, active: active)
                case .text: PreviewText(file: file)
                case .document, .spreadsheet, .presentation: PreviewWeb(file: file)
                case .model, nil: PreviewStill(preview: preview, file: file)
                #else
                default: QuickLookPage(file: file)
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
