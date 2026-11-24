#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        view.yieldsFocus = view.holdsFocus
        view.isHidden = true
        view.host.rootView = AnyView(EmptyView())
    }

    /// 块的大小只由外面给的框定（`frame(width:)`、铺满的高）：不答的话 SwiftUI 按 Auto Layout 量这块的合适大小，每次换宽都把整棵子树的约束灌进引擎走一遍。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WideColumnView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: WideColumnView, context: Context) {
        if slot == nil, view.slot != nil, view.holdsFocus { Task { [focus] in focus.focus(.pane(.main)) } }
        view.slot = slot
        if let layer = view.layer, let page = view.host.layer { view.slide.move(layer, page: page, origin: origin, width: width, shape: shape, leading: slot == .pane(.main), arrival: arrival) }
        view.dropUnder = under
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
    var dropUnder: CGFloat = 0
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

    var holdsFocus: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: self) == true }
    /// 撤掉时焦点还在这一块里：等它离开窗口，交给最左那块。当场交的话，这块里的页随后拆掉时 SwiftUI 把窗口的焦点又清一次。
    /// 滑走的块（`slot` 变成 nil）还留在窗口里，当场就交（`WideColumnHost.updateNSView`）。
    var yieldsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, yieldsFocus { Task { [focus] in focus.focus(.pane(.main)) } }
    }

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
        let carried = Set((sender.draggingPasteboard.types ?? []).map(\.rawValue))
        let types = Set(WideDrop.types.filter { carried.contains($0.identifier) })
        let x = convert(sender.draggingLocation, from: nil).x
        let column = slot?.column
        let onPage = types.contains(.cuepadCard) && column.flatMap { workspace.pane(in: $0)?.page } != nil
        let taken = pass(onPage ? cardTarget(sender) : nil, sender)
        let target = taken.isEmpty ? column.flatMap { WideDrop.target(types, at: x / max(1, bounds.width - dropUnder), in: $0, workspace: workspace) } : nil
        if workspace.dropTarget != target { workspace.dropTarget = target }
        return target == nil ? taken : .copy
    }

    /// 从页里拖起的卡先转给底下的页问：看板换列、灵感拖到任务上、任务行排序都是页里自己的落点。
    /// AppKit 按登记的类型认定最上面这层（`catcher`）是落点以后，它答"不接"也不会再去问底下的视图，得自己转。
    private var passed: (view: NSView, takes: Bool)?

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

    private func pass(_ view: NSView?, _ sender: any NSDraggingInfo) -> NSDragOperation {
        if let passed, passed.view !== view { passed.view.draggingExited(sender) }
        guard let view else {
            passed = nil
            return []
        }
        let operation = passed?.view === view ? view.draggingUpdated(sender) : view.draggingEntered(sender)
        passed = (view, !operation.isEmpty)
        return operation
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
        passed?.view.draggingExited(sender)
        passed = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let passed {
            self.passed = nil
            if passed.takes { return passed.view.prepareForDragOperation(sender) && passed.view.performDragOperation(sender) }
            passed.view.draggingExited(sender)
        }
        let target = workspace.dropTarget
        workspace.dropTarget = nil
        guard let target, target.column == slot?.column else { return false }
        do {
            guard let pane = try pane(in: sender.draggingPasteboard) else { return false }
            return WideDrop.apply(pane, target, workspace: workspace)
        } catch {
            workspace.fail(error)
            return false
        }
    }

    private func pane(in pasteboard: NSPasteboard) throws -> WideNavigation.Pane? {
        for type in WideDrop.types {
            if let data = pasteboard.data(forType: .init(type.identifier)) { return try WideDrop.pane(type, data, window: focus.windowID, workspace: workspace) }
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
#endif
