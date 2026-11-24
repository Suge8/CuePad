#if os(iOS)
import SwiftUI
import CueStore
import UniformTypeIdentifiers

nonisolated private final class LayoutMark: CALayer {
    var laidOut: (@MainActor () -> Void)?

    override func layoutSublayers() {
        super.layoutSublayers()
        let laidOut = laidOut
        MainActor.assumeIsolated { laidOut?() }
    }
}

final class WideColumnController: UIHostingController<AnyView> {
    /// 主区的一块（否则是 Cue 那一栏）。
    let pane: Bool
    var slot: WideSlot?
    var dropUnder: CGFloat = 0
    var passedDrop: (interaction: UIDropInteraction, takes: Bool)?
    let focus: WideFocus
    let workspace: Workspace
    private(set) lazy var slide = WideColumnSlide { [unowned self] in self.view.isHidden = $0 }
    /// 块的图层最后一个子层：CA 提交时按层树先父后子排版，排到它时这一次提交里块里各处托管的页都已摆到层上，页里各层的补位在这里接上（`WideColumnSlide.laidOut`）。
    /// 在块自己排完时（`viewDidLayoutSubviews`）接的话，SwiftUI 还没把页摆到层上，补的全是 0，居中的、靠右的只跟着整块平移、第一帧先跳到反方向。
    /// 会话页在导航栈里另有一个托管视图，下一次提交才摆：下一圈再排它一次、补上新挪的（`WideColumnSlide.layoutPasses`）。
    private let lastLayout = LayoutMark()
    init(pane: Bool, focus: WideFocus, workspace: Workspace) {
        self.pane = pane
        self.focus = focus
        self.workspace = workspace
        super.init(rootView: AnyView(EmptyView()))
        // 只认容器的安全区(键盘不认:块排在窗口的键盘安全区里,键盘升起时整块变矮)。块的下沿伸到窗口下缘（`reachesWindowBottom`），
        // 横条那一截照它在窗口里盖住多少算成页的下安全区：回复框停在横条上方，对话滚到窗口下缘、在横条后面透出来（同手机）
        safeAreaRegions = .container
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }

    /// 托管视图默认铺系统底色（白、深色下黑），会盖住窗口的桌面色（`SplitRoot`）：页没画到的地方——会话的栏头、Cue 那一栏名牌两侧——露出一条白。主区铺桌面色（`WideColumnHost`）。
    /// 按栏的框裁：滑动时右缘随图层的宽走（`WideColumnSlide`）。Cue 那一块宽一直不变、不裁：它是抽屉时面板阴影与伸进状态栏的面落在块外（`CueDock`）。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = pane
        lastLayout.laidOut = { [unowned self] in
            slide.laidOut(view.layer)
            guard slide.awaitsLayout else { return }
            Task { [weak self] in self?.lastLayout.setNeedsLayout() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 每次排完都挪回最后：页排版时可能在它后面加了层
        if slide.awaitsLayout {
            view.layer.addSublayer(lastLayout)
            lastLayout.setNeedsLayout()
        }
        installDropTargets(in: view)
    }

    private func installDropTargets(in target: UIView) {
        guard pane else { return }
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
    @objc private func left() { focus.move(by: -1, in: workspace) }
    @objc private func right() { focus.move(by: 1, in: workspace) }
}

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
        controller.slide.move(controller.view.layer, page: controller.view.layer, origin: origin, width: width, shape: shape, leading: slot == .pane(.main), arrival: arrival)
        controller.dropUnder = under
        controller.rootView = AnyView(content.modifier(WideEnvironment(workspace: workspace, values: environment)).environment(alerts).environment(\.wideWindowID, focus.windowID))
        controller.slide.park(hidden)
        if controller.pane { controller.view.backgroundColor = UIColor(cgColor: environment.palette.desk.resolve(in: environment).cgColor) }
    }
}

extension WideColumnController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        guard pane else { return false }
        return session.hasItemsConforming(toTypeIdentifiers: WideDrop.types.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        let types = Set(WideDrop.types.filter { session.hasItemsConforming(toTypeIdentifiers: [$0.identifier]) })
        let column = slot?.column
        let onPage = types.contains(.cuepadCard) && column.flatMap { workspace.pane(in: $0)?.page } != nil
        let taken = pass(onPage ? pageDrop(beside: interaction, session) : nil, session)
        let target = taken == nil ? column.flatMap { WideDrop.target(types, at: session.location(in: view).x / max(1, view.bounds.width - dropUnder), in: $0, workspace: workspace) } : nil
        if workspace.dropTarget != target { workspace.dropTarget = target }
        return taken ?? UIDropProposal(operation: target == nil ? .cancel : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        stopPassing(session)
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        if let page = passedDrop?.interaction { page.delegate?.dropInteraction?(page, sessionDidEnd: session) }
        passedDrop = nil
        if let column = slot?.column { WideDrop.leave(column, workspace: workspace) }
    }

    /// 同一个视图上有几个接收器时 UIKit 只问其中一个（iPadOS 27 实测：页的托管视图上 SwiftUI 的接收器与这里加的并存，整场只问这里的），
    /// 这里答"不接"也不会再去问别的。所以页里自己的落点由这里转着问：同一个视图上 SwiftUI 的那个接收器（它不答 canHandle，UIKit 当作能接）。
    private func pageDrop(beside ours: UIDropInteraction, _ session: any UIDropSession) -> UIDropInteraction? {
        ours.view?.interactions.lazy.compactMap { $0 as? UIDropInteraction }.first { other in
            guard other !== ours, let delegate = other.delegate else { return false }
            return delegate.dropInteraction?(other, canHandle: session) ?? true
        }
    }

    private func pass(_ page: UIDropInteraction?, _ session: any UIDropSession) -> UIDropProposal? {
        if let passed = passedDrop?.interaction, passed !== page { passed.delegate?.dropInteraction?(passed, sessionDidExit: session) }
        guard let page, let delegate = page.delegate else {
            passedDrop = nil
            return nil
        }
        if passedDrop?.interaction !== page { delegate.dropInteraction?(page, sessionDidEnter: session) }
        let proposal = delegate.dropInteraction?(page, sessionDidUpdate: session)
        let takes = proposal.map { $0.operation != .cancel && $0.operation != .forbidden } ?? false
        passedDrop = (page, takes)
        return takes ? proposal : nil
    }

    private func stopPassing(_ session: any UIDropSession) {
        if let page = passedDrop?.interaction { page.delegate?.dropInteraction?(page, sessionDidExit: session) }
        passedDrop = nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        if let passed = passedDrop {
            passedDrop = nil
            if passed.takes {
                passed.interaction.delegate?.dropInteraction?(passed.interaction, performDrop: session)
                return
            }
            passed.interaction.delegate?.dropInteraction?(passed.interaction, sessionDidExit: session)
        }
        let target = workspace.dropTarget
        workspace.dropTarget = nil
        guard let target, target.column == slot?.column, let provider = session.items.first?.itemProvider,
              let type = WideDrop.types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return }
        load(provider, type) { [workspace] result in
            do {
                if let pane = try result.get() { WideDrop.apply(pane, target, workspace: workspace) }
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func load(_ provider: NSItemProvider, _ type: UTType, _ done: @escaping @MainActor (Result<WideNavigation.Pane?, any Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [workspace, window = focus.windowID] data, error in
            Task { @MainActor in
                done(Result {
                    if let error { throw error }
                    return try WideDrop.pane(type, data ?? Data(), window: window, workspace: workspace)
                })
            }
        }
    }
}
#endif
