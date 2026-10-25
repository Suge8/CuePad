#if os(iOS)
import CueStore
import SwiftUI

extension View {
    /// 点交付物后的全屏页：同一组的几份左右翻，每类由 CuePad 自己显示（`PreviewPage`；网页与文稿只读、不联网）。
    /// 从点的那张缩略图放大出来（系统 zoom 转场），下滑缩回翻到的那一份原处；减弱动态效果时整块交叉淡入淡出。
    /// `reply` 是这一页的底栏对谁说（`PreviewOpening.reply` 另给的除外）。一个页面只在这里挂一次，不在每张缩略图上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>, reply: PreviewReply) -> some View {
        modifier(PreviewPresenter(opened: opened, reply: reply))
    }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    let reply: PreviewReply
    /// 呈现着的那一份：跟着 `opened` 走，只多管一件事——减弱动态效果时不带呈现动画地换上（不滑上来，全屏页自己淡入，`PreviewPager.shown`）。
    /// 调用处直接写 `opened`，写的那一下的动画由它们定，这里另起一个事务才拦得住。
    @State private var presented: PreviewOpening?
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.previewZoom, reduceMotion ? nil : zoom)
            .environment(\.openPreview, PreviewOpener { opened = $0 })
            .onChange(of: opened, initial: true) { _, next in
                var transaction = Transaction()
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction) { presented = next }
            }
            .panel(item: Binding { presented } set: { presented = $0; opened = $0 }, style: .fullScreen) {
                PreviewPager(opening: $0, reply: $0.reply ?? reply, current: $0.preview.id, zoom: reduceMotion ? nil : zoom)
            }
    }
}

/// 全屏页：系统顶栏（左关闭、中间标题与"第几份 · 类型"、右分享），标题是当前这一份（写法同缩略图下那行），内容紧接着铺满，
/// 底部一条玻璃栏（`PreviewReplyBar`）。
private struct PreviewPager: View {
    let opening: PreviewOpening
    let reply: PreviewReply
    @State var current: UUID
    let zoom: Namespace.ID?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 减弱动态效果时整页的淡入淡出
    @State private var shown = false
    /// 往下拉了多少（`PageSwipe`）
    @State private var pull: CGFloat = 0
    /// 图片页放大着：拖动是看图，不是收起
    @State private var zoomedIn = false

    private var batch: [PiPreview] { opening.batch }
    private var index: Int { opening.index(of: current) }
    private var preview: PiPreview { batch[index] }
    private var title: String { opening.title(of: preview) }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(batch) { page in
                    PreviewContent(preview: page, file: file(of: page), active: page.id == current)
                        .environment(\.previewZoomedIn, page.id == current ? $zoomedIn : .constant(false))
                        .tag(page.id)
                }
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
            .navigationSubtitle(opening.position(at: index).visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { dismiss() } }
                if let file = file(of: preview) { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) } }
            }
            .safeAreaBar(edge: .bottom) {
                PreviewReplyBar(reply: reply, about: title, done: dismiss)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
        }
        .zoomed(from: PreviewZoomKey(group: opening.group, preview: current), in: zoom)
        .opacity(reduceMotion && !shown ? 0 : 1)
        .presentationBackground(reduceMotion ? .clear : palette.desk)
        .onAppear { if reduceMotion { withAnimation(Motion.crossfade) { shown = true } } }
    }

    /// 拉过这么多松手就收起
    private static let pullToClose: CGFloat = 110

    /// 关掉：减弱动态效果时先淡出再无动画地收起，其余照系统的（缩回那张缩略图）。
    private func dismiss() {
        if reduceMotion {
            withAnimation(Motion.crossfade) { shown = false } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { close() }
            }
            return
        }
        close()
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.url(of: preview)
    }
}

extension EnvironmentValues {
    /// 翻到的图片页放大着（这时拖动是看图，不收起）；翻页留着的邻页拿到的是常量
    @Entry var previewZoomedIn: Binding<Bool> = .constant(false)
}

private extension View {
    @ViewBuilder func zoomed(from key: PreviewZoomKey, in namespace: Namespace.ID?) -> some View {
        if let namespace { navigationTransition(.zoom(sourceID: key, in: namespace)) } else { self }
    }
}

/// 全屏页上的下拉收起（挂在整个翻页上，所有页都接得到）：UIKit 的拖动手势，开始那一刻看方向——往下、手指下面的滚动区都在顶上、
/// 图片没放大时才接，跟着手指往下走，松手过一截就收起、缩回缩略图原处；横着的当场放弃交给分页翻页（页里横着能滚的先滚到头，再滑就翻）。
/// 和页里自己的滚动同时认（SwiftUI 的拖动手势会把翻页与页里的滚动一起吃掉）。系统 zoom 转场自带的下滑收起在翻页的分页里接不到手势，所以自己接。
struct PageSwipe: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let pulled: (CGFloat) -> Void
    let released: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) { pan.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let down = max(pan.translation(in: pan.view).y, 0)
        switch pan.state {
        case .changed: pulled(down)
        case .ended, .cancelled: released(down)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return velocity.y > abs(velocity.x) && !Self.scrolledDown(under: pan.location(in: view), in: view)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// 手指下面有往下翻过的滚动区：这一拉是往回翻，不是收起。
        private static func scrolledDown(under point: CGPoint, in root: UIView) -> Bool {
            var view = root.hitTest(point, with: nil)
            while let current = view, current !== root {
                if let scroll = current as? UIScrollView, scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 { return true }
                view = current.superview
            }
            return false
        }
    }
}
#endif
