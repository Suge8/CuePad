#if os(iOS)
import CueStore
import SwiftUI

extension View {
    /// 点交付物后的全屏页：同一组的几份左右翻，每类由 CuePad 自己显示（`PreviewPage`；网页与文稿只读、不联网）。
    /// 从点的那张缩略图放大出来（系统 zoom 转场），关掉时缩回翻到的那一份原处；减弱动态效果时系统自己把转场降成淡入淡出、关闭手势照旧（实测）。
    /// 飞出来的第一帧就有图：等点的那张缩略图交出画面（`previewSource`，一般已在内存里）再呈现，页里大图解好前先铺它。
    /// `reply` 是这一页的底栏对谁说（`PreviewOpening.reply` 另给的除外）。一个页面只在这里挂一次，不在每张缩略图上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>, reply: PreviewReply) -> some View {
        modifier(PreviewPresenter(opened: opened, reply: reply))
    }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    let reply: PreviewReply
    /// 呈现着的那一份：跟着 `opened` 走，晚一步——点的那张的画面取到了才换上（关掉是同时）。
    @State private var presented: PreviewOpening?
    @State private var sources = PreviewSources()
    @Namespace private var zoom

    func body(content: Content) -> some View {
        content
            .environment(\.previewZoom, zoom)
            .environment(\.previewSources, sources)
            .environment(\.openPreview, PreviewOpener { opened = $0 })
            .task(id: opened) {
                if let opened { await sources.prepare(PreviewZoomKey(group: opened.group, preview: opened.preview.id)) }
                presented = opened
            }
            .panel(item: Binding { presented } set: { presented = $0; opened = $0 }, style: .fullScreen) {
                PreviewPager(opening: $0, reply: $0.reply ?? reply, current: $0.preview.id, zoom: zoom, sources: sources)
            }
    }
}

/// 全屏页：页顶那一排（左关闭、中间一块玻璃写标题与"第几份 · 类型"、右分享，`floatingHeader`），标题是当前这一份（写法同缩略图下那行），
/// 底部一条玻璃栏（`PreviewReplyBar`）。内容铺满整屏、从两条栏后面透出来，没放大时排在两条栏之间。
/// 关掉的手势全是系统 zoom 转场的（下拉、左缘右滑、双指捏小），跟着手指缩回翻到的那一份；页里放大着、往下翻过或左边还有一份时由 `PreviewDismissGuard` 让给页里。
/// 接了键盘：左右方向键翻页，Esc 关闭。
private struct PreviewPager: View {
    let opening: PreviewOpening
    let reply: PreviewReply
    @State var current: UUID
    let zoom: Namespace.ID
    let sources: PreviewSources
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 两条栏与状态栏占的边（`previewInsets`）
    @State private var insets = EdgeInsets()

    private var batch: [PiPreview] { opening.batch }
    private var index: Int { opening.index(of: current) }
    private var preview: PiPreview { batch[index] }
    private var title: String { opening.title(of: preview) }

    var body: some View {
        NavigationStack {
            pages
            .floatingHeader(.verbatim(title), detail: opening.position(at: index)) {
                share
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", icon: .close, role: .cancel) { close() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                PreviewReplyBar(reply: reply, about: title) { close() }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            .background { PageKeys(turn: turn) { close() } }
        }
        .overlay { StatusBarBlur() }
        .navigationTransition(.zoom(sourceID: PreviewZoomKey(group: opening.group, preview: current), in: zoom))
        .presentationBackground(palette.desk)
    }

    @ViewBuilder private var share: some View {
        if let file = file(of: preview) { ShareLink(item: file) { Image(.share).accessibilityLabel("分享") } }
    }

    /// 左右翻的几份：系统的分页（UIKit 的分页滚动区，相邻的一份提前建好，翻过去时图已经解好）；翻到哪一份只有 `current` 一份。
    /// 不用 `ScrollView` 的分页：它翻页松手后只按 60Hz 出帧，邻页要露头才建（模拟器逐帧录屏实测，改版前的 `TabView` 松手后 120Hz）。
    private var pages: some View {
        TabView(selection: $current) {
            ForEach(batch) { page in
                // 分页铺满整屏、页里拿不到安全区：栏占的边在这里给回去，会滚的页再自己铺到栏后面（`previewInsets`）
                PreviewContent(preview: page, file: file(of: page), active: page.id == current).safeAreaPadding(insets).tag(page.id)
                    .environment(\.previewLook, PreviewLook(sources: sources, key: PreviewZoomKey(group: opening.group, preview: page.id)))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // 栏后面不垫系统的滚动边缘效果（docs/ui.md「沉浸式的栏」）：SwiftUI 这一层与分页滚动区自己那一层（`PreviewDismissGuard`）都关
        .scrollEdgeEffectHidden()
        .environment(\.previewInsets, insets)
        .ignoresSafeArea()
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        .background { PreviewDismissGuard() }
        .background(palette.desk)
    }

    /// 往前、往后翻一份（键盘），到头不动。
    private func turn(_ step: Int) {
        let next = index + step
        guard batch.indices.contains(next) else { return }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { current = batch[next].id }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.url(of: preview)
    }
}

/// 接了键盘时左右方向键翻页、Esc 关闭（同照片 App）。系统的键盘焦点也要方向键（在按钮之间挪焦点），这里的键要排在它前面，
/// SwiftUI 的快捷键排不过它，所以挂一个 UIKit 的接键视图：全屏页一出来就接键，在底栏里打字时键归输入框。
private struct PageKeys: UIViewRepresentable {
    let turn: (Int) -> Void
    let close: () -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.turn = turn
        view.close = close
    }

    final class Catcher: UIView {
        var turn: (Int) -> Void = { _ in }
        var close: () -> Void = {}

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { becomeFirstResponder() }
        }

        override var keyCommands: [UIKeyCommand]? {
            [(UIKeyCommand.inputLeftArrow, #selector(back)), (UIKeyCommand.inputRightArrow, #selector(forward)), (UIKeyCommand.inputEscape, #selector(escape))]
                .map { input, action in
                    let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                    command.wantsPriorityOverSystemBehavior = true
                    return command
                }
        }

        @objc private func back() { turn(-1) }
        @objc private func forward() { turn(1) }
        @objc private func escape() { close() }
    }
}


#endif
