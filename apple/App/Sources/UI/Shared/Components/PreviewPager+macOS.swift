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
            .environment(\.openPreview, PreviewOpener { opened = $0 })
            .environment(\.previewFlight, flight)
            // 关法（Esc、点外面、关闭钮、说完）都经这里：先让翻到的那一份飞回去
            .panel(item: Binding { opened } set: { next in
                if next == nil { flight.land() }
                opened = next
            }, style: .fullScreen) {
                PreviewPager(opening: $0, reply: $0.reply ?? reply, flight: flight, current: $0.preview.id)
                    .frame(maxWidth: PanelStyle.previewSize.width, maxHeight: PanelStyle.previewSize.height)
            }
    }
}

extension PanelStyle {
    static let previewSize = CGSize(width: 960, height: 760)
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

    private var batch: [PiPreview] { opening.batch }
    private var paged: Bool { batch.count > 1 }
    private var index: Int { opening.index(of: current) }
    private var preview: PiPreview { batch[index] }
    private var title: String { opening.title(of: preview) }
    private var chrome: EdgeInsets { EdgeInsets(top: Self.headerHeight, leading: 0, bottom: barHeight, trailing: 0) }

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
        .background {
            PreviewFlight.Stage(
                flight: flight, key: PreviewZoomKey(group: opening.group, preview: preview.id), kind: preview.kind,
                page: preview.kind == .web && file(of: preview) != nil ? preview.key : nil, chrome: chrome, landed: $landed)
        }
        // 读屏先读顶栏（标题、第几份、翻页、分享、关闭），再读内容，最后是底栏：顶栏是叠在内容上的，不排的话排在内容后面
        .overlay(alignment: .top) { header.accessibilitySortPriority(1) }
        .overlay(alignment: .bottom) {
            if let reply {
                PreviewReplyBar(reply: reply, preview: preview, about: title, entry: opening.entry, done: { close() })
                    .frame(maxWidth: 640).padding([.horizontal, .bottom], Spacing.block)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height + 16 } action: { barHeight = $0 }
            }
        }
        .background(palette.desk)
        .background { PageInput { step($0) } }
    }

    private var header: some View {
        Text(title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .padding(.horizontal, Spacing.block).frame(height: ControlMetrics.height)
            .glass(in: .capsule)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Self.titleRoom)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: Spacing.item) {
                    stepper
                    if let file = file(of: preview) {
                        ShareLink(item: file) { Label("分享", icon: .share).labelStyle(.iconOnly) }
                            .buttonStyle(ControlButtonStyle(kind: .circular))
                    }
                    Button("关闭", icon: .close) { close() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ControlButtonStyle(kind: .circular))
                        .help("关闭（Esc）")
                }
            }
            .padding(.horizontal, Self.edge).padding(.top, Self.edge)
    }

    private var stepper: some View {
        HStack(spacing: Spacing.tight) {
            if paged {
                Button("上一个", icon: .back) { step(-1) }.labelStyle(.iconOnly).disabled(index == 0).help("上一个（←）")
            }
            Text(opening.position(at: index)).font(Typography.caption).foregroundStyle(palette.ink2).monospacedDigit()
                .padding(.horizontal, paged ? 0 : Spacing.tight)
            if paged {
                Button("下一个", icon: .forward) { step(1) }.labelStyle(.iconOnly).disabled(index == batch.count - 1).help("下一个（→）")
            }
        }
        .buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink2)
        .padding(.horizontal, Spacing.group).frame(height: ControlMetrics.height)
        .glass(in: .capsule)
    }

    private func step(_ offset: Int) {
        guard let next = opening.neighbor(of: current, step: offset) else { return }
        withAnimation(Motion.fade) { current = next }
    }

    private func file(of preview: PiPreview) -> URL? {
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
