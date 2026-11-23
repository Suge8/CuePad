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
    let drop = WideDropState()
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
#endif
