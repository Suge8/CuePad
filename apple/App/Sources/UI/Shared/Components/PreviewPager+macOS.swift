#if os(macOS)
import CueStore
import SwiftUI

extension View {
    func previewPresenter(_ opened: Binding<PreviewOpening?>, reply: PreviewReply?) -> some View {
        modifier(PreviewPresenter(opened: opened, reply: reply))
    }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    let reply: PreviewReply?
    @State private var flight = PreviewFlight()

    func body(content: Content) -> some View {
        content
            .environment(\.openPreview, PreviewOpener(owner: ObjectIdentifier(flight)) { opened = $0 })
            .environment(\.previewFlight, flight)
            // 关法（Esc、点外面、关闭钮、说完）都经这里：先让翻到的那一份飞回去
            .panel(item: Binding { opened } set: { next in
                if next == nil { flight.land() }
                opened = next
            }, style: .fullScreen) {
                PreviewPager(opening: $0, reply: $0.reply ?? reply, flight: flight, current: $0.preview.id)
                    .frame(maxWidth: PreviewContent.page.width, maxHeight: PreviewContent.page.height)
            }
    }
}

/// 翻页原地交叉淡（同快速查看与"预览"）：Mac 上换一张不滑，滑动要逐帧挪整页。
private struct PreviewPager: View {
    let opening: PreviewOpening
    let reply: PreviewReply?
    let flight: PreviewFlight
    @State var current: UUID
    @State private var barHeight: CGFloat = 0
    @State private var landed = false
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close

    private var batch: [PreviewItem] { opening.batch }
    private var paged: Bool { batch.count > 1 }
    private var index: Int { opening.index(of: current) }
    private var preview: PreviewItem { batch[index] }
    private var title: String { opening.title(of: preview) }
    /// 图片与网页铺满整页、两条栏的玻璃浮在上面（同"照片"）：让出栏的话，高图的上沿齐着顶栏切一刀，网页顶上多一条桌面色的空带。
    /// 别的页是从头读的字，让出栏。
    private var chrome: EdgeInsets {
        [.image, .web].contains(preview.kind) ? EdgeInsets() : EdgeInsets(top: Self.headerHeight, leading: 0, bottom: barHeight, trailing: 0)
    }

    var body: some View {
        ZStack {
            PreviewContent(preview: preview, file: file(of: preview))
                .safeAreaPadding(chrome)
                .id(preview.id)
                .transition(.opacity)
        }
        .environment(\.previewInsets, chrome)
        .environment(\.previewFlight, flight)
        .opacity(landed ? 1 : 0)
        // 飞来的那一小页是淡成内容的，内容也淡着出来；别的在飞的那张底下当场换
        .animation(preview.kind.thumbnail == .page ? Motion.fade : nil, value: landed)
        .background {
            PreviewFlight.Stage(
                flight: flight, key: PreviewZoomKey(group: opening.group, preview: preview.id), kind: preview.kind,
                page: preview.kind == .web && file(of: preview) != nil ? preview.key : nil, chrome: chrome, landed: $landed)
        }
        // 读屏先读顶栏（标题、第几份、关闭）与翻页钮，再读内容，最后是底栏：它们是叠在内容上的，不排的话排在内容后面
        // 这几样浮在内容上的钮等画面飞到了才淡出来：飞的那张在最上面，先露出来的话被它盖过去、等它化掉又冒出来
        .overlay {
            ZStack {
                header.frame(maxHeight: .infinity, alignment: .top).accessibilitySortPriority(1)
                if paged { turns.accessibilitySortPriority(1) }
                if let reply {
                    PreviewReplyBar(reply: reply, preview: preview, about: title, entry: opening.entry, done: { close() })
                        .frame(maxWidth: 640).padding([.horizontal, .bottom], Spacing.block)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height + 16 } action: { barHeight = $0 }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .opacity(landed ? 1 : 0)
            .animation(Motion.fade, value: landed)
        }
        .background(palette.desk)
        .background { PageInput { step($0) } }
    }

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            if let kind = preview.kind {
                Image(kind == .image ? .photo : DeliverableTile.icon(kind)).font(Typography.caption).foregroundStyle(palette.ink2)
                    .iconLabel(kind.label).help(Text(verbatim: kind.label))
            }
            Text(title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
        }
            .padding(.horizontal, Spacing.block).frame(height: ControlMetrics.height)
            .glass(in: .capsule)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Self.titleRoom)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: Spacing.item) {
                    if paged { stepper }
                    Button("关闭", icon: .close) { close() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ControlButtonStyle(kind: .circular))
                        .help("关闭（Esc）")
                }
            }
            .padding(.horizontal, Self.edge).padding(.top, Self.edge)
    }

    private var stepper: some View {
        Text(verbatim: "\(index + 1) / \(batch.count)").font(Typography.caption).foregroundStyle(palette.ink2).monospacedDigit()
            .padding(.horizontal, Spacing.group + Spacing.tight).frame(height: ControlMetrics.height)
            .glass(in: .capsule)
    }

    /// 翻页钮在内容的左右两侧、竖直居中（同快速查看与"照片"）：往哪边翻钮就在哪边，不挤在右上角那一排小字旁边。到头的那一侧没有钮。
    private var turns: some View {
        HStack {
            if index > 0 {
                Button("上一个", icon: .back) { step(-1) }.help("上一个（←）").transition(.opacity)
            }
            Spacer(minLength: 0)
            if index < batch.count - 1 {
                Button("下一个", icon: .forward) { step(1) }.help("下一个（→）").transition(.opacity)
            }
        }
        .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .circular))
        .padding(.horizontal, Self.edge)
    }

    private func step(_ offset: Int) {
        guard let next = opening.neighbor(of: current, step: offset) else { return }
        withAnimation(Motion.fade) { current = next }
    }

    private func file(of preview: PreviewItem) -> URL? {
        services.store.files.fileURL(for: preview.key)
    }

    private static let edge = Spacing.group
    private static let headerHeight = edge + ControlMetrics.height + 8
    private static let titleRoom: CGFloat = 200
}

/// 全屏页开着时本窗口的翻页输入（本地事件监听，先于页里的视图）：
/// - ←→：焦点在输入框里（回复栏打字）时归输入框；
/// - 触控板横扫：一次横扫开始时看指针下的内容往那边还滑不滑得动（放大了的图、放大了的 PDF），滑得动就整次归它，滑到边也只回弹；
///   滑不动的（没放大、已滑到那一边、视频、网页）整次归翻页，扫过 `swipe` 点翻一页、一次至多一页，之后的几下与惯性都吞掉。看图和翻页不抢。
private struct PageInput: NSViewRepresentable {
    let step: (Int) -> Void

    func makeNSView(context: Context) -> Watch { Watch() }
    func updateNSView(_ view: Watch, context: Context) { view.step = step }

    final class Watch: NSView {
        var step: ((Int) -> Void)?
        private var monitor: Any?
        private var swipe: Swipe?

        fileprivate enum Swipe {
            case undecided
            case content
            case paging(CGFloat?)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.takes(event) == true } ? nil : event
            }
            DebugHooks.previewScrolls { [weak self] in self?.takes($0) == true }
        }

        private func takes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            return event.type == .keyDown ? key(event, in: window) : scroll(event, in: window)
        }

        private func key(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty,
                  !(window.firstResponder is NSText)
            else { return false }
            switch event.keyCode {
            case Self.left: step?(-1)
            case Self.right: step?(1)
            default: return false
            }
            return true
        }

        private func scroll(_ event: NSEvent, in window: NSWindow) -> Bool {
            if !event.phase.isDisjoint(with: [.mayBegin, .began]) { swipe = .undecided }
            if event.phase.isEmpty, event.momentumPhase.isEmpty { swipe = nil }
            switch swipe {
            case nil, .content: return false
            case .undecided:
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                guard dx != 0 || dy != 0 else { return false }
                let horizontal = abs(dx) > abs(dy)
                swipe = horizontal && !Self.scrolls(at: event.locationInWindow, in: window, toward: dx) ? .paging(dx) : .content
                return horizontal && swipe.isPaging
            case .paging(let distance):
                guard let distance else { return true }
                let moved = distance + event.scrollingDeltaX
                guard abs(moved) > Self.distance else {
                    swipe = .paging(moved)
                    return true
                }
                // 手指往左（内容往左走）是下一份
                step?(moved < 0 ? 1 : -1)
                swipe = .paging(nil)
                return true
            }
        }

        private static func scrolls(at point: NSPoint, in window: NSWindow, toward dx: CGFloat) -> Bool {
            var view = window.contentView?.superview?.hitTest(point)
            while let current = view, !(current is NSScrollView) { view = current.superview }
            guard let scroll = view as? NSScrollView, let document = scroll.documentView else { return false }
            let visible = scroll.documentVisibleRect, frame = document.frame
            return dx > 0 ? visible.minX > frame.minX + 0.5 : visible.maxX < frame.maxX - 0.5
        }

        private static let distance: CGFloat = 40
        private static let left: UInt16 = 123
        private static let right: UInt16 = 124
    }
}

private extension Optional where Wrapped == PageInput.Watch.Swipe {
    var isPaging: Bool { if case .paging = self { true } else { false } }
}
#endif
