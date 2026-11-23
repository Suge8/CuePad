import SwiftUI
import CueStore
import UniformTypeIdentifiers

enum WideSlot: Hashable, CaseIterable {
    case main, beside(Int), cue

    static let allCases: [WideSlot] = [.main] + (0..<WideNavigation.maxPanes - 1).map(WideSlot.beside) + [.cue]

    init(_ column: Workspace.Column) {
        switch column {
        case .main: self = .main
        case .beside(let index): self = .beside(index)
        }
    }

    var column: Workspace.Column? {
        switch self {
        case .main: .main
        case .beside(let index): .beside(index)
        case .cue: nil
        }
    }
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
        let shown = WideSlot.allCases.filter { view($0) != nil }
        #else
        let shown = WideSlot.allCases.filter { controller($0) != nil }
        #endif
        guard !shown.isEmpty else { return }
        let next = current.flatMap(shown.firstIndex).map { (shown.index(after: $0)) % shown.count } ?? 0
        focus(shown[next])
    }

    func move(by step: Int, in workspace: Workspace) {
        if let source = current?.column { workspace.moveColumn(source, by: step) }
    }
}

#if os(macOS)
struct WideColumnHost<Content: View>: NSViewRepresentable {
    /// 这一块此刻在第几格；不在这一排里（挂着的页、正滑走的块）是 nil。
    let slot: WideSlot?
    let focus: WideFocus
    let origin: CGFloat
    let width: CGFloat
    let shape: WideMetrics.Shape
    var hidden = false
    var under: CGFloat = 0
    var arrival: WideColumnSlide.Arrival?
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(PanelHost.self) private var panels

    func makeNSView(context: Context) -> WideColumnView {
        let view = WideColumnView(pane: slot != .cue, focus: focus, workspace: workspace)
        focus.register(view)
        return view
    }

    /// 撤掉的块当场不画、不留内容：嵌着的托管视图同外面断开时会把页从头再摆一遍，摆的是下一帧就扔的东西。
    static func dismantleNSView(_ view: WideColumnView, coordinator: ()) {
        view.isHidden = true
        view.host.rootView = AnyView(EmptyView())
    }

    /// 块的大小只由外面给的框定（`frame(width:)`、铺满的高）：不答的话 SwiftUI 按 Auto Layout 量这块的合适大小，每次换宽都把整棵子树的约束灌进引擎走一遍。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WideColumnView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: WideColumnView, context: Context) {
        view.slot = slot
        if let layer = view.layer, let page = view.host.layer { view.slide.move(layer, page: page, origin: origin, width: width, shape: shape, leading: slot == .main, arrival: arrival) }
        view.drop.under = under
        // 宽和内容一起给：等 SwiftUI 来摆这块的框要晚一步，页已经按旧的宽、新的内容（`underCue`）排过一遍——
        // 从并排的窄块换到最左、垫进 Cue 底下的那一下，对话被当成只有二十几点宽排了一次
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        view.host.rootView = AnyView(content.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(panels).environment(\.wideWindowID, focus.windowID))
        view.slide.park(hidden)
        if view.pane { view.host.layer?.backgroundColor = environment.palette.desk.resolve(in: environment).cgColor }
    }
}

/// 每一块的托管视图：按下不当成拖窗口。块的栏头在窗口最顶那一排（标题栏里）：标题栏按按下那一点最深的视图问它能不能拖窗口，
/// 答"能"的那一下整个归标题栏、内容收不到（同 `isMovable` 无关），嵌着的托管视图默认答"能"，栏头的钮就点不进去。
/// 栏头的空处要拖窗口的由栏头自己挂系统的拖窗口手势（`windowDragArea`）。
/// 窗口不在前台时第一下就交给内容（同栏头那一排在窗口自己的托管视图里、会话条上的钮）：不然主区与 Cue 栏头的钮第一下只把窗口叫到前面。
/// 页按新宽排完（`super.layout`）报给块（`laidOut`）：块换宽时页里各层的补位在这里接上（`WideColumnSlide.laidOut`）。
final class ColumnHostingView: NSHostingView<AnyView> {
    var laidOut: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        laidOut?()
    }
}

final class WideColumnView: NSView {
    let host = ColumnHostingView(rootView: AnyView(EmptyView()))
    let drop = WideDropState()
    /// 主区的一块（否则是 Cue 那一栏）。
    let pane: Bool
    var slot: WideSlot?
    let focus: WideFocus
    let workspace: Workspace
    private(set) lazy var slide = WideColumnSlide { [unowned self] in self.isHidden = $0 }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(pane: Bool, focus: WideFocus, workspace: Workspace) {
        self.pane = pane
        self.focus = focus
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = pane
        host.sizingOptions = []
        host.laidOut = { [unowned self] in if let page = host.layer { slide.laidOut(page) } }
        // 不带标题栏那一截安全区：页里的滚动区不再向上伸到栏头底下（伸上去时按下落在滚动视图上，栏头的钮点不进去）；那一排页自己按 `Chrome.band` 让出
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        host.wantsLayer = true
        if pane { addSubview(catcher) }
    }

    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        host.frame = bounds
        catcher.frame = bounds
    }

    /// 拖放交给指针下最深一层登记过这种类型的视图、不往外传：对话里的文字视图、回复框都登记着，挂在块上的接收器只接得到栏头那一条。
    /// 所以盖一层在最上面专接主区的几种拖放，鼠标照常穿过它（`hitTest` 为 nil）。
    private lazy var catcher = DropCatcher(owner: self)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if drop.drag != sender.draggingSequenceNumber {
            drop.drag = sender.draggingSequenceNumber
            drop.pane = try? pane(in: pasteboard)
        }
        let carried = Set((pasteboard.types ?? []).map(\.rawValue))
        let types = Set(WideDrop.types.filter { carried.contains($0.identifier) })
        let x = convert(sender.draggingLocation, from: nil).x
        let target = slot?.column.flatMap { WideDrop.target(types, dragged: drop.pane, at: x / max(1, bounds.width - drop.under), in: $0, workspace: workspace) }
        if workspace.dropTarget != target { workspace.dropTarget = target }
        guard target == nil else {
            pass(nil, sender)
            return .copy
        }
        let onPage = slot?.column.flatMap { workspace.pane(in: $0)?.page } != nil
        return pass(onPage && types.contains(.cuepadCard) ? cardTarget(sender) : nil, sender)
    }

    /// 主区不接的那一下转给底下的页：看板换列、灵感拖到任务上、任务行排序都是页里自己的落点。
    /// AppKit 按登记的类型认定最上面这层（`catcher`）是落点以后，它答"不接"也不会再去问底下的视图，得自己转。
    private weak var passed: NSView?

    /// 底下接卡的那一层：指针下最深的、登记了卡这种类型的视图（AppKit 自己也这么找）。SwiftUI 的每个落点是一层这样的视图，登记的是卡的上位类型。
    /// 只认卡：拖放还带着系统附的文件承诺，照"带着的任何一种"去找，会转给回复框、对话里的文字视图，被它们当文件收下。
    private func cardTarget(_ sender: any NSDraggingInfo) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            // 容器不先量：SwiftUI 的容器视图不一定框得住里面的
            for inner in view.subviews.reversed() { if let found = find(inner) { return found } }
            let takes = view.registeredDraggedTypes.contains { Self.card.contains($0.rawValue) }
            return takes && view.bounds.contains(view.convert(sender.draggingLocation, from: nil)) ? view : nil
        }
        return find(host)
    }

    private static let card = Set(([.cuepadCard] + UTType.cuepadCard.supertypes).map(\.identifier))

    @discardableResult private func pass(_ view: NSView?, _ sender: any NSDraggingInfo) -> NSDragOperation {
        if passed !== view { passed?.draggingExited(sender) }
        defer { passed = view }
        guard let view else { return [] }
        return passed === view ? view.draggingUpdated(sender) : view.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        stopPassing(sender)
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        stopPassing(sender)
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    private func stopPassing(_ sender: (any NSDraggingInfo)?) {
        passed?.draggingExited(sender)
        passed = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let passed {
            self.passed = nil
            return passed.prepareForDragOperation(sender) && passed.performDragOperation(sender)
        }
        let target = workspace.dropTarget
        workspace.dropTarget = nil
        guard let target, target.column == slot?.column else { return false }
        do {
            guard let pane = try pane(in: sender.draggingPasteboard) ?? nil else { return false }
            return WideDrop.apply(pane, target, workspace: workspace)
        } catch {
            workspace.fail(error)
            return false
        }
    }

    /// 拖的是哪一块：nil 是剪贴板上还读不出（按类型猜），`.some(nil)` 是读出来了但主区不接（任务卡）。同一个 App 里拖的，拖着时就读得出。
    private func pane(in pasteboard: NSPasteboard) throws -> WideNavigation.Pane?? {
        for type in WideDrop.types {
            if let data = pasteboard.data(forType: .init(type.identifier)) { return .some(try WideDrop.pane(type, data, window: focus.windowID, workspace: workspace)) }
        }
        return nil
    }

    @objc func switchWideFocus(_ sender: Any?) { focus.cycle() }

    private final class DropCatcher: NSView {
        unowned let owner: WideColumnView

        init(owner: WideColumnView) {
            self.owner = owner
            super.init(frame: .zero)
            registerForDraggedTypes(WideDrop.types.map { .init($0.identifier) })
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { owner.draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { owner.draggingUpdated(sender) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { owner.draggingExited(sender) }
        override func draggingEnded(_ sender: any NSDraggingInfo) { owner.draggingEnded(sender) }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { owner.performDragOperation(sender) }
    }
    @objc func moveWideLeft(_ sender: Any?) { focus.move(by: -1, in: workspace) }
    @objc func moveWideRight(_ sender: Any?) { focus.move(by: 1, in: workspace) }
}
#else
struct WideColumnHost<Content: View>: UIViewControllerRepresentable {
    /// 这一块此刻在第几格；不在这一排里（挂着的页、正滑走的块）是 nil。
    let slot: WideSlot?
    let focus: WideFocus
    let origin: CGFloat
    let width: CGFloat
    let shape: WideMetrics.Shape
    var hidden = false
    var under: CGFloat = 0
    var arrival: WideColumnSlide.Arrival?
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(AlertCenter.self) private var alerts

    func makeUIViewController(context: Context) -> WideColumnController {
        let controller = WideColumnController(pane: slot != .cue, focus: focus, workspace: workspace)
        focus.register(controller)
        return controller
    }

    func updateUIViewController(_ controller: WideColumnController, context: Context) {
        controller.slot = slot
        controller.slide.move(controller.view.layer, page: controller.view.layer, origin: origin, width: width, shape: shape, leading: slot == .main, arrival: arrival)
        controller.drop.under = under
        controller.rootView = AnyView(content.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(alerts).environment(\.wideWindowID, focus.windowID))
        controller.slide.park(hidden)
        if controller.pane { controller.view.backgroundColor = UIColor(cgColor: environment.palette.desk.resolve(in: environment).cgColor) }
    }
}
#endif

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
