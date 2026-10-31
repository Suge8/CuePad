import SwiftUI
import CueStore
import UniformTypeIdentifiers

/// 只保留控件引用，当前栏从系统第一响应者读取，不复制输入焦点状态。
final class WideFocus {
    let windowID = UUID()
    #if os(macOS)
    weak var main: WideColumnView?
    weak var side: WideColumnView?

    var current: Workspace.Column? {
        guard let responder = (main?.window ?? side?.window)?.firstResponder as? NSView else { return nil }
        if let main, responder.isDescendant(of: main) { return .main }
        if let side, responder.isDescendant(of: side) { return .side }
        return nil
    }

    func focus(_ column: Workspace.Column) {
        guard let view = column == .main ? main : side else { return }
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
    weak var main: WideColumnController?
    weak var side: WideColumnController?

    var current: Workspace.Column? {
        if let main, main.isFirstResponder || descendants(main.view).contains(where: \.isFirstResponder) { return .main }
        if let side, side.isFirstResponder || descendants(side.view).contains(where: \.isFirstResponder) { return .side }
        return nil
    }

    func focus(_ column: Workspace.Column) {
        guard let controller = column == .main ? main : side else { return }
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

    func cycle() { focus(current == .main ? .side : .main) }
}

#if os(macOS)
struct WideColumnHost<Content: View>: NSViewRepresentable {
    let column: Workspace.Column
    let focus: WideFocus
    let rail: CGFloat
    let origin: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(PanelHost.self) private var panels

    func makeNSView(context: Context) -> WideColumnView {
        let view = WideColumnView(column: column, focus: focus, workspace: workspace)
        if column == .main { focus.main = view } else { focus.side = view }
        return view
    }

    func updateNSView(_ view: WideColumnView, context: Context) {
        view.host.rootView = AnyView(content.overlay { WideDropFeedback(state: view.drop) }.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(panels).environment(\.wideWindowID, focus.windowID))
        view.move(rail: rail, origin: origin)
    }
}

final class WideColumnView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let drop = WideDropState()
    let column: Workspace.Column
    let focus: WideFocus
    let workspace: Workspace
    private var previous: (rail: CGFloat, origin: CGFloat)?
    private var sequence = 0
    override var acceptsFirstResponder: Bool { true }

    init(column: Workspace.Column, focus: WideFocus, workspace: Workspace) {
        self.column = column
        self.focus = focus
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes([.init(DraggedColumn.type.identifier), .init(UTType.cuepadSession.identifier)])
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); host.frame = bounds }

    func move(rail: CGFloat, origin: CGFloat) {
        defer { previous = (rail, origin) }
        guard let previous, previous.rail != rail, let layer else { return }
        sequence += 1
        SidebarSlide.translate(layer, by: previous.origin - origin, key: "wide.\(sequence)")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        drop.targeted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { drop.targeted = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { drop.targeted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        drop.targeted = false
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
    @objc func moveWideLeft(_ sender: Any?) { move(to: .main) }
    @objc func moveWideRight(_ sender: Any?) { move(to: .side) }

    private func move(to target: Workspace.Column) {
        guard let source = focus.current else { return }
        workspace.moveSession(from: source, to: target)
        Task {
            await NextFrame.wait()
            focus.focus(target)
        }
    }
}
#else
struct WideColumnHost<Content: View>: UIViewControllerRepresentable {
    let column: Workspace.Column
    let focus: WideFocus
    @ViewBuilder let content: Content
    @Environment(\.self) private var environment
    @Environment(Workspace.self) private var workspace
    @Environment(AlertCenter.self) private var alerts

    func makeUIViewController(context: Context) -> WideColumnController {
        let controller = WideColumnController(column: column, focus: focus, workspace: workspace)
        if column == .main { focus.main = controller } else { focus.side = controller }
        return controller
    }

    func updateUIViewController(_ controller: WideColumnController, context: Context) {
        controller.rootView = AnyView(content.overlay { WideDropFeedback(state: controller.drop) }.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(alerts).environment(\.wideWindowID, focus.windowID))
    }
}

final class WideColumnController: UIHostingController<AnyView> {
    let column: Workspace.Column
    let drop = WideDropState()
    let focus: WideFocus
    let workspace: Workspace
    init(column: Workspace.Column, focus: WideFocus, workspace: Workspace) {
        self.column = column
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
    @objc private func left() { move(to: .main) }
    @objc private func right() { move(to: .side) }
    private func move(to target: Workspace.Column) {
        guard let source = focus.current else { return }
        workspace.moveSession(from: source, to: target)
        Task {
            await NextFrame.wait()
            focus.focus(target)
        }
    }
}
#endif

/// Hosting 边界只传页面需要的环境，避免两栏共用 SwiftUI 内部的焦点与无障碍桥。
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
