import SwiftUI
import CueStore
import UniformTypeIdentifiers

/// 宽屏窗口里各自托管的几块：主区（并排时是左半）、并排的右半、右边的 Cue。各是一个托管视图，两块不共用 SwiftUI 内部的焦点与无障碍桥。
enum WideSlot: CaseIterable {
    case main, beside, cue

    /// 放会话的那一边（Cue 不是）。
    var column: Workspace.Column? {
        switch self {
        case .main: .main
        case .beside: .beside
        case .cue: nil
        }
    }
}

/// 只保留控件引用，当前栏从系统第一响应者读取，不复制输入焦点状态。⌃Tab 在看得见的几块之间轮换（主区、并排的右半、Cue）。
final class WideFocus {
    let windowID = UUID()
    #if os(macOS)
    private var views: [WideSlot: Weak] = [:]

    private struct Weak { weak var view: WideColumnView? }

    func register(_ view: WideColumnView, as slot: WideSlot) { views[slot] = Weak(view: view) }

    private func view(_ slot: WideSlot) -> WideColumnView? {
        guard let view = views[slot]?.view, view.window != nil, !view.isHidden else { return nil }
        return view
    }

    var current: WideSlot? {
        guard let responder = WideSlot.allCases.lazy.compactMap({ self.view($0)?.window }).first?.firstResponder as? NSView else { return nil }
        return WideSlot.allCases.first { slot in view(slot).map(responder.isDescendant(of:)) == true }
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
    private var controllers: [WideSlot: Weak] = [:]

    private struct Weak { weak var controller: WideColumnController? }

    func register(_ controller: WideColumnController, as slot: WideSlot) { controllers[slot] = Weak(controller: controller) }

    private func controller(_ slot: WideSlot) -> WideColumnController? {
        guard let controller = controllers[slot]?.controller, controller.view.window != nil, !controller.view.isHidden else { return nil }
        return controller
    }

    var current: WideSlot? {
        WideSlot.allCases.first { slot in
            guard let controller = controller(slot) else { return false }
            return controller.isFirstResponder || descendants(controller.view).contains(where: \.isFirstResponder)
        }
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
        let shown = WideSlot.allCases.filter { view($0) != nil }
        #else
        let shown = WideSlot.allCases.filter { controller($0) != nil }
        #endif
        guard !shown.isEmpty else { return }
        let next = current.flatMap(shown.firstIndex).map { (shown.index(after: $0)) % shown.count } ?? 0
        focus(shown[next])
    }

    /// ⌘⌥← / →：有焦点的会话挪向那一边（只在并排两个会话时有可挪的），焦点跟着它过去。
    func move(to target: Workspace.Column, in workspace: Workspace) {
        guard let source = current?.column else { return }
        workspace.moveSession(from: source, to: target)
        Task {
            await NextFrame.wait()
            focus(target == .main ? .main : .beside)
        }
    }
}

#if os(macOS)
struct WideColumnHost<Content: View>: NSViewRepresentable {
    let slot: WideSlot
    let focus: WideFocus
    let origin: CGFloat
    let width: CGFloat
    /// 会话条与 Cue 的宽：它们一变，这一块滑到新位置（`WideColumnView.move`）；只是窗口改宽时不滑。
    let shape: WideMetrics.Shape
    /// 收起的 Cue 仍挂着（回来时对话、滚动位置都在），只是藏起：看不见、点不到、⌃Tab 跳过。
    var hidden = false
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(PanelHost.self) private var panels

    func makeNSView(context: Context) -> WideColumnView {
        let view = WideColumnView(slot: slot, focus: focus, workspace: workspace)
        focus.register(view, as: slot)
        return view
    }

    func updateNSView(_ view: WideColumnView, context: Context) {
        view.host.rootView = AnyView(content.overlay { WideDropFeedback(state: view.drop) }.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(panels).environment(\.wideWindowID, focus.windowID))
        view.isHidden = hidden
        view.move(origin: origin, width: width, shape: shape)
    }
}

/// 每一块的托管视图：按下不当成拖窗口。块的栏头在窗口最顶那一排（标题栏里）：标题栏按按下那一点最深的视图问它能不能拖窗口，
/// 答"能"的那一下整个归标题栏、内容收不到（同 `isMovable` 无关），嵌着的托管视图默认答"能"，栏头的钮就点不进去。
/// 栏头的空处要拖窗口的由栏头自己挂系统的拖窗口手势（`windowDragArea`）。
/// 窗口不在前台时第一下就交给内容（同栏头那一排在窗口自己的托管视图里、会话条上的钮）：不然主区与 Cue 栏头的钮第一下只把窗口叫到前面。
final class ColumnHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WideColumnView: NSView {
    let host = ColumnHostingView(rootView: AnyView(EmptyView()))
    let drop = WideDropState()
    let slot: WideSlot
    let focus: WideFocus
    let workspace: Workspace
    private var previous: (origin: CGFloat, width: CGFloat, shape: WideMetrics.Shape)?
    private var sequence = 0
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(slot: WideSlot, focus: WideFocus, workspace: Workspace) {
        self.slot = slot
        self.focus = focus
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        // 按栏的框裁（矩形裁剪，不离屏）：滑动时右缘随图层的宽走（`move`）
        clipsToBounds = true
        host.sizingOptions = []
        // 不带标题栏那一截安全区：页里的滚动区不再向上伸到栏头底下（伸上去时按下落在滚动视图上，栏头的钮点不进去）；那一排页自己按 `WideMetrics.band` 让出
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        // 会话拖进主区的两边；Cue 那一块不接
        if slot.column != nil { registerForDraggedTypes([.init(DraggedColumn.type.identifier), .init(UTType.cuepadSession.identifier)]) }
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); host.frame = bounds }

    /// 会话条换宽、Cue 收起或放回时，各块这一下就到了终点的位置与宽（页按新的宽排一次），看得见的滑动是渲染端的两段叠加动画（`SidebarSlide`，主线程不逐帧挪）：
    /// 整块从旧位置平移回来，右缘从旧宽收放到新宽。几块平移的距离不同（主区随会话条的边，并排的右半随两半的分界），只平移的话主区已按终点排宽、
    /// 又多平移了一截，滑动途中右缘压进右边那一块；按终点的框裁又在两块之间露出一道缝。
    /// 图层的宽按同一条曲线从旧宽走到新宽（图层的锚点在左上，只动右缘；页的排版不跟着变）：相邻两块的边每一帧都对齐，
    /// 几段偏移随同一条弹簧按比例收敛（离终点的比例只随时间走，与距离无关）。
    func move(origin: CGFloat, width: CGFloat, shape: WideMetrics.Shape) {
        defer { previous = (origin, width, shape) }
        guard let previous, previous.shape != shape, let layer else { return }
        sequence += 1
        SidebarSlide.translate(layer, by: previous.origin - origin, key: "wide.\(sequence)")
        SidebarSlide.slide(layer, "bounds.size.width", by: previous.width - width, key: "wide.edge.\(sequence)")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        drop.targeted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { drop.targeted = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { drop.targeted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        drop.targeted = false
        guard let column = slot.column else { return false }
        let pasteboard = sender.draggingPasteboard
        do {
            if let data = pasteboard.data(forType: .init(DraggedColumn.type.identifier)) {
                let value = try JSONDecoder().decode(DraggedColumn.self, from: data)
                workspace.dropSession(SessionRoute(id: value.recordID, sessionID: value.sessionID), in: column, movingWithinWindow: value.windowID == focus.windowID)
                return true
            }
            if let data = pasteboard.data(forType: .init(UTType.cuepadSession.identifier)) {
                let value = try JSONDecoder().decode(DraggedSession.self, from: data)
                workspace.openSession(PiSessionState.recordID(sessionID: value.sessionID), sessionID: value.sessionID, in: column)
                return true
            }
        } catch { workspace.fail(error) }
        return false
    }

    @objc func switchWideFocus(_ sender: Any?) { focus.cycle() }
    @objc func moveWideLeft(_ sender: Any?) { focus.move(to: .main, in: workspace) }
    @objc func moveWideRight(_ sender: Any?) { focus.move(to: .beside, in: workspace) }
}
#else
struct WideColumnHost<Content: View>: UIViewControllerRepresentable {
    let slot: WideSlot
    let focus: WideFocus
    var hidden = false
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(AlertCenter.self) private var alerts

    func makeUIViewController(context: Context) -> WideColumnController {
        let controller = WideColumnController(slot: slot, focus: focus, workspace: workspace)
        focus.register(controller, as: slot)
        return controller
    }

    func updateUIViewController(_ controller: WideColumnController, context: Context) {
        controller.rootView = AnyView(content.overlay { WideDropFeedback(state: controller.drop) }.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(alerts).environment(\.wideWindowID, focus.windowID))
        controller.view.isHidden = hidden
    }
}

final class WideColumnController: UIHostingController<AnyView> {
    let slot: WideSlot
    let drop = WideDropState()
    let focus: WideFocus
    let workspace: Workspace
    init(slot: WideSlot, focus: WideFocus, workspace: Workspace) {
        self.slot = slot
        self.focus = focus
        self.workspace = workspace
        super.init(rootView: AnyView(EmptyView()))
        safeAreaRegions = []
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installDropTargets(in: view)
    }

    private func installDropTargets(in target: UIView) {
        guard slot.column != nil else { return }
        let interactions = target.interactions.compactMap { $0 as? UIDropInteraction }
        // 列表与回复框自带接收器，会截住父栏的拖放；追加只认会话的接收器，保留原处理。
        if (target === view || !interactions.isEmpty) && !interactions.contains(where: { $0.delegate === self }) {
            target.addInteraction(UIDropInteraction(delegate: self))
        }
        target.subviews.forEach { installDropTargets(in: $0) }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\t", modifierFlags: .control, action: #selector(cycle)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .alternate], action: #selector(left)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.command, .alternate], action: #selector(right))
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func cycle() { focus.cycle() }
    @objc private func left() { focus.move(to: .main, in: workspace) }
    @objc private func right() { focus.move(to: .beside, in: workspace) }
}
#endif

/// Hosting 边界只传页面需要的环境，避免几块共用 SwiftUI 内部的焦点与无障碍桥。
private struct WideEnvironment: ViewModifier {
    let workspace: Workspace
    let values: EnvironmentValues

    func body(content: Content) -> some View {
        content
            .environment(workspace)
            .environment(workspace.services)
            .environment(\.palette, values.palette)
            .environment(\.colorScheme, values.colorScheme)
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
