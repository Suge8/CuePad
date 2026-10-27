#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 会话页的页头全在窗口工具栏上，内容区里不再另起一行页头。
/// 工具栏项在主窗口里常驻（`PageTitleSlot`、`PageMenuSlot`），随页面切换换里面的内容：增删工具栏项会重建整条工具栏，
/// 进出会话页、换会话时那要占点击回合的一半。会话页只把算好的值与动作交到这里；不是会话页时槽里是空的。
@Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        var title: String
        var undelivered: String?
        var ending: Bool
        var place: String?
        /// 本机桥上在线、开在终端里、知道是哪个终端的会话（可跳到终端，`PiSession.canJump`）。
        var liveID: CuePi.PiSession.ID?
        var canEnd: Bool
        var canRename: Bool
        /// 对话在看历史时标题让开。
        var showsHeader: Bool
        /// "⋯"里的菜单项晚于标题两帧建（建菜单约占点击回合的一半）。
        var showsMenu: Bool
        /// 这个会话在做哪几件事；读到前是 nil。
        var task: SessionTaskLink?
    }

    private(set) var state: State?
    @ObservationIgnored var rename: (PiSessionState) -> Void = { _ in }
    @ObservationIgnored var end: (PiSessionState) -> Void = { _ in }
    @ObservationIgnored var reveal: () -> Void = {}

    func set(_ state: State?) {
        if self.state != state { self.state = state }
    }

    /// 离开的会话页只清自己的：换会话时新页面的值可能已经先到了。
    func clear(_ sessionID: String) {
        if state?.session.sessionID == sessionID { state = nil }
    }
}

extension Workspace {
    /// 当前会话页的标题与菜单要显示的值；不是会话页时为 nil。
    var shownSessionHeader: SessionHeader.State? {
        guard case .session(let route) = root, let state = sessionHeader.state, state.session.sessionID == route.sessionID else { return nil }
        return state
    }
}

/// 工具栏居中的标题位（`.principal`，在详情区里居中，侧栏开合都与对话的阅读栏对齐）：一块玻璃，第一行会话名接状态（`PiSessionSubtitle`，只有着色的字、不画状态圆点：玻璃里唯一的圆是任务圈；只在在跑或要你注意时有；所在写在"⋯"菜单最上面）。
/// 绑着任务时玻璃里是提醒事项那样的一条：左边是这件事的完成圈（点它完成；会话绑着的事都做完了才结束），会话名下面一行小字写"任务 · 子任务"
/// （与会话名重复的一段不写，见 `SessionTaskLink.path`），点它回到这件事。一个会话绑着好几件时写还没做完的第一件，后面跟"等 N 件"，其余在"⋯"里。
/// 两行与一行同高（工具栏控件的高度）；会话的事都归档了或在回收站里时只有一行。
/// 玻璃画在标题自己身上、随它一起淡出：系统给工具栏项画的那块不随内容显隐，让开时会留下一块空玻璃。
/// 标题位与玻璃的尺寸只随窗口变、不随内容变：宽裕时是 `width`，窗口窄、侧栏收起时由工具栏压到最窄 `minWidth`（`ToolbarItemFlex`），
/// 不把左右的控件挤进溢出菜单，玻璃里的名字随之截断；窗口最窄（720）时也放得下。玻璃铺满标题位、内容靠左：
/// 玻璃按内容宽画再居中时，状态一换（进出"正在同步"、开始结束工作、计时进位）玻璃就变宽变窄、名字左右挪。
/// Cue 页的页头也在这一位（`CueTitle`，同一块玻璃、同样的宽度规则），只在侧栏收起时有（同 `ProjectSwitcher` 只在收起时写当前页）。
/// 一页里换看哪一段的分段也在这一位（技能与规则页，`LibraryPanesSlot`，同手机页顶中间）；进展页的例外见 `PanesSlot`。
/// 开着盖在页上的编辑页时这一位是它的标题与次要一行（`OverlayTitle`）。
struct PageTitleSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 工具栏里标题一块最宽多少：名字长时截断，不把右边的按钮挤走。
    fileprivate static let width: CGFloat = 420
    /// 窗口窄时标题位最多让到多窄（名字截断，状态照常）。
    fileprivate static let minWidth: CGFloat = 160

    var body: some View {
        if workspace.overlay != nil {
            OverlayTitle()
        } else if let state = workspace.shownSessionHeader {
            title(state)
        } else if workspace.root == .cue, workspace.pages.sidebar == .detailOnly {
            CueTitle()
                .frame(height: Spacing.toolbarControl)
                .modifier(PageTitleFlex())
        } else if workspace.root == .library {
            LibraryPanesSlot()
        }
    }

    private func title(_ state: SessionHeader.State) -> some View {
        let session = state.session, primary = state.task?.primary, task = primary?.task
        return HStack(spacing: 0) {
            if let task { ring(task) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.title).font(task == nil ? Typography.toolbarTitle : Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                        .lineLimit(1).layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                    if state.ending {
                        Text("正在结束…").font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
                    } else {
                        PiSessionSubtitle(session: session, undelivered: state.undelivered)
                    }
                }
                if let primary, let line = state.task?.path(below: state.title) { path(primary, line) }
            }
        }
        .padding(.leading, task == nil ? 12 : 4).padding(.trailing, task == nil ? 12 : 14)
        .frame(height: Spacing.toolbarControl)
        .accessibilityElement(children: .contain)
        // 标题位的宽度只看工具栏给多少：随内容变时换会话整条工具栏重排、整窗重算鼠标跟踪区，掉帧 8 次到 4～5 次
        .modifier(PageTitleFlex())
        .opacity(state.showsHeader ? 1 : 0)
        .animation(HandOff.quick, value: state.showsHeader)
        .allowsHitTesting(state.showsHeader)
        .accessibilityHidden(!state.showsHeader)
        // 让开时这一块仍接指针：移上去或点一下唤出
        .background {
            if !state.showsHeader {
                Color.clear.contentShape(.rect)
                    .onHover { if $0 { workspace.sessionHeader.reveal() } }
                    .onTapGesture { workspace.sessionHeader.reveal() }
            }
        }
    }


    /// 这件事的完成圈：命中区占满玻璃的高度。完成了只显示对勾（回到待办在任务那边做）。
    private func ring(_ task: Card) -> some View {
        let done = task.status == .done
        return Button { workspace.completeTask(task.id) } label: {
            TaskRingView(status: task.status, done: done, size: 15)
                .frame(width: 30, height: Spacing.toolbarControl)
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .disabled(done)
        .help(done ? "这件事已完成" : "完成任务：打勾；会话绑着的事都做完了就结束它")
        .accessibilityLabel(done ? "任务已完成" : "完成任务")
    }

    /// 会话名下面的"任务 · 子任务"（绑着好几件时后面"等 N 件"）：点它回到这件事（项目页，任务气泡翻到这一步）。
    private func path(_ item: LeafTask, _ line: Dotted) -> some View {
        Button { workspace.showTask(item.task) } label: {
            Text(line)
                .font(Typography.toolbarPath).foregroundStyle(palette.ink3).lineLimit(1)
        }
        .buttonStyle(PressStyle())
        .help("回到这件事")
    }
}

/// 标题位在 `minWidth`～`width` 之间由工具栏给：理想宽写最窄（工具栏按理想宽量最少要多宽），能放多宽由 `ToolbarItemFlex` 告诉工具栏。玻璃铺满给的宽。
struct PageTitleFlex: ViewModifier {
    var alignment = Alignment.leading

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .glass(in: .capsule)
            .frame(minWidth: PageTitleSlot.minWidth, idealWidth: PageTitleSlot.minWidth, maxWidth: PageTitleSlot.width)
            .background { ToolbarItemFlex(width: PageTitleSlot.minWidth...PageTitleSlot.width) }
    }
}

/// 让所在的工具栏项能在 `width` 之间伸缩：SwiftUI 的工具栏项只报理想宽、按它定死，窗口一窄就整项挤进溢出菜单（实测）。
/// 工具栏按项的视图的约束量尺寸（`NSToolbarItem.view`，macOS 12 起不用 minSize、maxSize），这里给那个视图加上宽的上下限，
/// 并把它守住理想宽的优先级降到"量最小尺寸"那一档之下：工具栏量到最窄是下限，有地方时放宽到上限。
/// 上下限只在挂着时有：标题位空了（别的页）就撤下，空的标题位不占着下限那么宽、不挡住下面页里的东西（项目页的回到顶部）。
/// 降下的优先级留着（再挂上时一样，标题位换内容时新旧两份前后脚挂撤，各管各的上下限）。
private struct ToolbarItemFlex: NSViewRepresentable {
    let width: ClosedRange<CGFloat>

    func makeNSView(context: Context) -> Probe { Probe(width: width) }
    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        let width: ClosedRange<CGFloat>
        private var limits: [NSLayoutConstraint] = []

        init(width: ClosedRange<CGFloat>) {
            self.width = width
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSLayoutConstraint.deactivate(limits)
            limits = []
            guard let host = window?.toolbar?.items.first(where: { $0.view.map(isDescendant) ?? false })?.view else { return }
            let yielding = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
            host.setContentHuggingPriority(yielding, for: .horizontal)
            host.setContentCompressionResistancePriority(yielding, for: .horizontal)
            limits = [host.widthAnchor.constraint(greaterThanOrEqualToConstant: width.lowerBound), host.widthAnchor.constraint(lessThanOrEqualToConstant: width.upperBound)]
            NSLayoutConstraint.activate(limits)
        }
    }
}

/// "⋯"里会话页的那几项：最上面写所在；绑着的每件没完成的事一项"完成"；"绑定到任务"再绑一件（本项目还没绑会话的叶子任务）；
/// "解除绑定"正在用它的那几件（以前用过它的不在这里解）；
struct SessionMenuItems: View {
    let state: SessionHeader.State
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let session = state.session
        if let place = state.place { Section { } header: { Text(place) } }
        if let link = state.task {
            let open = link.tasks.filter { $0.task.status != .done }
            ForEach(open) { item in
                Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", icon: .complete) { workspace.completeTask(item.task.id) }
            }
            if !link.bindable.isEmpty {
                Menu("绑定到任务", icon: .link) {
                    ForEach(link.bindable) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) {
                            let (sessionID, task) = (session.sessionID, item.task.id)
                            workspace.perform { try await $0.bindSession(sessionID, to: task) }
                        }
                    }
                }
            }
            let using = link.tasks.filter { $0.task.piSessionID == session.sessionID }
            if !using.isEmpty {
                Menu("解除绑定", icon: .unlink) {
                    ForEach(using) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) { unbind(item.task.id) }
                    }
                }
            }
            Divider()
        }
        if state.canRename {
            Button("重命名…", icon: .rename) { workspace.sessionHeader.rename(state.session) }
        }
        if let id = state.liveID {
            Button("跳到终端窗口", icon: .terminalWindow) { workspace.jumpToTerminal(id) }
        }
        if state.canEnd {
            Button("结束会话", icon: .endSession, role: .destructive) { workspace.sessionHeader.end(state.session) }
                .disabled(state.ending)
        }
    }

    private func unbind(_ task: UUID) { workspace.perform { try await $0.unbindSession(from: task) } }
}
/// 会话属于的事（正在用它的与以前用过它的，含做完了的，先开始的在前）与本项目还能绑的。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    var tasks: [LeafTask]
    var bindable: [LeafTask]

    /// 标题里写的那一件：还没做完的第一件，都做完了是第一件。
    var primary: LeafTask? { tasks.first { $0.task.status != .done } ?? tasks.first }

    /// 会话名下面那一行"任务 · 子任务"（绑着好几件时后面"等 N 件"）：与会话名相同的一段不再写（从任务开的会话以叶子的标题命名），
    /// 什么都不剩时没有这一行。
    func path(below title: String) -> Dotted? {
        guard let primary else { return nil }
        let named = [primary.parent?.title, primary.task.title].filter { $0 != title }
        return Dotted(named + [tasks.count > 1 ? String(localized: "等 \(tasks.count) 件") : nil]).nonEmpty
    }

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        SessionTaskLink(tasks: try store.tasks(boundTo: sessionID), bindable: try store.bindableTasks(in: project))
    }
}

extension Workspace {
    /// 回到会话做的那件事：项目页，任务气泡翻到这一步（从点的那一下长出来）。
    func showTask(_ task: Card) {
        show(.project(task.projectID))
        open(task)
    }

    /// 完成会话绑着的任务：完成就是做完了，会话绑着的事都做完了就结束（见 `toggle`）。
    func completeTask(_ id: UUID) {
        attempt { try await self.toggle(id) }
    }
}
#endif
