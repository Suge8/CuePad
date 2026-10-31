import SwiftUI

/// 只保留控件引用，当前栏从系统第一响应者读取，不复制输入焦点状态。
final class WideFocus {
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
        let input = descendants(view).compactMap { $0 as? NSTextView }.last { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        view.window?.makeFirstResponder(input ?? view)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    #else
    weak var main: UIView?
    weak var side: UIView?

    var current: Workspace.Column? {
        if let main, descendants(main).contains(where: \.isFirstResponder) { return .main }
        if let side, descendants(side).contains(where: \.isFirstResponder) { return .side }
        return nil
    }

    func focus(_ column: Workspace.Column) {
        guard let view = column == .main ? main : side else { return }
        let input = descendants(view).compactMap { $0 as? UITextView }.last { $0.isEditable && !$0.isHidden }
        (input ?? view).becomeFirstResponder()
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
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
        view.host.rootView = AnyView(content.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(panels))
        view.move(rail: rail, origin: origin)
    }
}

final class WideColumnView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
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
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); host.frame = bounds }

    func move(rail: CGFloat, origin: CGFloat) {
        defer { previous = (rail, origin) }
        guard let previous, previous.rail != rail, let layer else { return }
        sequence += 1
        SidebarSlide.translate(layer, by: previous.origin - origin, key: "wide.\(sequence)")
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
        let controller = WideColumnController(focus: focus, workspace: workspace)
        if column == .main { focus.main = controller.view } else { focus.side = controller.view }
        return controller
    }

    func updateUIViewController(_ controller: WideColumnController, context: Context) {
        controller.rootView = AnyView(content.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(alerts))
    }
}

final class WideColumnController: UIHostingController<AnyView> {
    let focus: WideFocus
    let workspace: Workspace
    init(focus: WideFocus, workspace: Workspace) {
        self.focus = focus
        self.workspace = workspace
        super.init(rootView: AnyView(EmptyView()))
        safeAreaRegions = []
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\t", modifierFlags: .control, action: #selector(cycle)),
         UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .alternate], action: #selector(left)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.command, .alternate], action: #selector(right))]
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
            #endif
    }
}
