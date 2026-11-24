import SwiftUI

/// 一块此刻在哪：主区的第几块，或 Cue 那一栏。
enum WideSlot: Hashable {
    case pane(Workspace.Column)
    case cue

    /// 键盘轮换焦点的次序：主区从左到右，最后是 Cue。
    static let order: [WideSlot] = (0..<WideNavigation.maxPanes).map { .pane(Workspace.Column(index: $0)) } + [.cue]

    var column: Workspace.Column? { if case .pane(let column) = self { column } else { nil } }
}

/// 一个宽屏窗口里几块之间的焦点。块按它是什么认（`PaneRow`），第几格（`WideSlot`）只是它此刻的位置：换了位置还是那一块，焦点、滚动都留在它身上。
final class WideFocus {
    let windowID = UUID()
    private var rows: (was: WideMetrics?, now: WideMetrics?)

    /// 这一排变成现在的样子之前（刚开窗时没有）。新摆出来的块没有自己的旧位置，照它定从哪儿进来（`WideColumnSlide.Arrival`）；滑走的块照它留着原来的宽。
    /// 样子没变（拖分隔线、视图体重算）问几次答的都是那一个。
    func before(_ sizes: WideMetrics) -> WideMetrics? {
        if rows.now?.shape != sizes.shape { rows.was = rows.now }
        rows.now = sizes
        return rows.was
    }

    #if os(macOS)
    private var views: [Weak] = []

    private struct Weak { weak var view: WideColumnView? }

    func register(_ view: WideColumnView) {
        views.removeAll { $0.view == nil }
        views.append(Weak(view: view))
    }

    private func view(_ slot: WideSlot) -> WideColumnView? {
        views.lazy.compactMap(\.view).first { $0.slot == slot && $0.window != nil && !$0.isHidden }
    }

    var current: WideSlot? {
        guard let responder = views.lazy.compactMap({ $0.view?.window }).first?.firstResponder as? NSView else { return nil }
        return views.lazy.compactMap(\.view).first(where: responder.isDescendant(of:))?.slot
    }

    func focus(_ slot: WideSlot) {
        guard let view = view(slot) else { return }
        let input = descendants(view).compactMap { $0 as? NSTextView }.last { $0.isEditable && visible($0) }
        view.window?.makeFirstResponder(input ?? view)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.filter(visible).flatMap { [$0] + descendants($0) }
    }

    private func visible(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden && $0.alphaValue > 0 && $0.layer?.opacity != 0 }
    }
    #else
    private var controllers: [Weak] = []

    private struct Weak { weak var controller: WideColumnController? }

    func register(_ controller: WideColumnController) {
        controllers.removeAll { $0.controller == nil }
        controllers.append(Weak(controller: controller))
    }

    private func controller(_ slot: WideSlot) -> WideColumnController? {
        controllers.lazy.compactMap(\.controller).first { $0.slot == slot && $0.view.window != nil && !$0.view.isHidden }
    }

    var current: WideSlot? {
        controllers.lazy.compactMap(\.controller).first { $0.isFirstResponder || descendants($0.view).contains(where: \.isFirstResponder) }?.slot
    }

    func focus(_ slot: WideSlot) {
        guard let controller = controller(slot) else { return }
        let input = descendants(controller.view).compactMap { $0 as? UITextView }.last { $0.isEditable }
        (input as UIResponder? ?? controller).becomeFirstResponder()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.filter(visible).flatMap { [$0] + descendants($0) }
    }

    private func visible(_ view: UIView) -> Bool {
        sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden && $0.alpha > 0 && $0.layer.opacity > 0 && $0.isUserInteractionEnabled }
    }
    #endif

    func cycle() {
        #if os(macOS)
        let shown = WideSlot.order.filter { view($0) != nil }
        #else
        let shown = WideSlot.order.filter { controller($0) != nil }
        #endif
        guard !shown.isEmpty else { return }
        let next = current.flatMap(shown.firstIndex).map { (shown.index(after: $0)) % shown.count } ?? 0
        focus(shown[next])
    }

    func move(by step: Int, in workspace: Workspace) {
        if let source = current?.column { workspace.moveColumn(source, by: step) }
    }
}

/// Hosting 边界只传页面需要的环境，避免几块共用 SwiftUI 内部的焦点与无障碍桥。
struct WideEnvironment: ViewModifier {
    let workspace: Workspace
    let values: EnvironmentValues

    func body(content: Content) -> some View {
        content
            .environment(workspace)
            .environment(workspace.services)
            .environment(\.colorScheme, values.colorScheme)
            .environment(\._colorSchemeContrast, values.colorSchemeContrast)
            .environment(\.locale, values.locale)
            .environment(\.dynamicTypeSize, values.dynamicTypeSize)
            .environment(\.panelCovered, values.panelCovered)
            .environment(\.pageActive, values.pageActive)
            .environment(\.relayStage, values.relayStage)
            .environment(\.openPreview, values.openPreview)
            #if os(macOS)
            .environment(\.previewFlight, values.previewFlight)
            #else
            .environment(\.previewSources, values.previewSources)
            .environment(\.previewZoom, values.previewZoom)
            .environment(\.zoomNamespace, values.zoomNamespace)
            #endif
    }
}
