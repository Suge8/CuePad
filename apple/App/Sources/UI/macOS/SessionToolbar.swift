#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 会话页的页头全在窗口工具栏上：居中的标题（会话名接状态，绑着任务时下面一行是这件事，左边是它的完成圈）与右上"⋯"里的会话操作
/// （所在、完成任务、绑定到任务、解除绑定、重命名、跳到终端、结束会话）。内容区里不再另起一行页头。
/// 工具栏项在主窗口里常驻（`SessionTitleSlot`、`PageMenuSlot`），随页面切换换里面的内容：增删工具栏项会重建整条工具栏，
/// 进出会话页、换会话时那要占点击回合的一半。会话页只把算好的值与动作交到这里；不是会话页时槽里是空的。
@Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        var title: String
        var undelivered: String?
        /// 由 Cue 跟进（`SessionDigest.cueFollows`）。
        var cueFollows: Bool
        var ending: Bool
        /// "⋯"最上面写的所在。
        var place: Dotted?
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
        guard case .session(let route) = page, let state = sessionHeader.state, state.session.sessionID == route.sessionID else { return nil }
        return state
    }
}

/// 工具栏居中的标题位（`.principal`，在详情区里居中，侧栏开合都与对话的阅读栏对齐）：一块玻璃，第一行会话名接状态（`PiSessionSubtitle`，只有着色的字、不画状态圆点：玻璃里唯一的圆是任务圈；只在在跑或要你注意时有；所在写在"⋯"菜单最上面）。
/// 绑着任务时玻璃里是提醒事项那样的一条：左边是这件事的完成圈（点它完成；会话绑着的事都做完了才结束），会话名下面一行小字写"任务 · 步骤"，
/// 点它回到这件事。一个会话绑着好几件时写还没做完的第一件，后面跟"等 N 件"，其余在"⋯"里。
/// 两行与一行同高（工具栏控件的高度），没绑任务时只有一行。
/// 玻璃画在标题自己身上、随它一起淡出：系统给工具栏项画的那块不随内容显隐，让开时会留下一块空玻璃。
/// 玻璃只包住内容、在标题位里居中（最宽 `width`，名字再长就截断）。标题位的尺寸只随窗口变、不随内容变（项的尺寸一变整条工具栏重排）：
/// 宽裕时是 `width`，窗口窄、侧栏收起时让到最窄 `minWidth`，不压到左上的侧栏钮、项目切换与右上的搜索、任务、"⋯"，玻璃里的名字随之截断。
struct SessionTitleSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 点标题弹出的说明（需要 /reload 时）开着。
    @State private var explaining = false

    /// 工具栏里标题一块最宽多少：名字长时截断，不把右边的按钮挤走。
    private static let width: CGFloat = 420
    /// 窗口窄时标题位最多让到多窄（名字截断，状态照常）。
    private static let minWidth: CGFloat = 160

    var body: some View {
        if let state = workspace.shownSessionHeader {
            title(state)
        }
    }

    private func title(_ state: SessionHeader.State) -> some View {
        let session = state.session, primary = state.task?.primary, task = primary?.task
        return HStack(spacing: 0) {
            if let task { ring(task) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 会话绑着的事里有一件由 Cue 跟进（`CueStore.cueFollowedSessions`），不只看标题里写的那一件
                    if state.cueFollows {
                        CueFollowMark().alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                    Text(state.title).font(task == nil ? Typography.toolbarTitle : Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                        .lineLimit(1).layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                    if state.ending {
                        Text("正在结束…").font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
                    } else {
                        PiSessionSubtitle(session: session, undelivered: state.undelivered, cueFollows: state.cueFollows)
                    }
                }
                if let primary { path(primary, count: state.task?.tasks.count ?? 1) }
            }
        }
        .padding(.leading, task == nil ? 12 : 4).padding(.trailing, task == nil ? 12 : 14)
        .frame(height: Spacing.toolbarControl)
        .glass(in: .capsule)
        .accessibilityElement(children: .contain)
        // 需要 /reload 的会话：状态就写在这块玻璃里，点它看怎么接上（不在对话上另浮一张卡）
        .contentShape(.capsule)
        .onTapGesture { if state.showsHeader, PiShown(session).explanation != nil { explaining = true } }
        .explanationPopover(PiShown(session).explanation, isPresented: $explaining)
        // 标题位的宽度只看工具栏给多少（玻璃只画到内容那么宽）：随内容变时换会话整条工具栏重排、整窗重算鼠标跟踪区，掉帧 8 次到 4～5 次
        .frame(maxWidth: .infinity)
        .frame(minWidth: Self.minWidth, idealWidth: Self.width, maxWidth: Self.width)
        .opacity(state.showsHeader ? 1 : 0)
        .animation(Motion.quick, value: state.showsHeader)
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
            TaskRingView(status: task.status, ring: .plain, done: done, size: 15)
                .frame(width: 30, height: Spacing.toolbarControl)
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .disabled(done)
        .help(done ? "这件事已完成" : "完成任务：打勾；会话绑着的事都做完了就结束它")
        .accessibilityLabel(done ? "任务已完成" : "完成任务")
    }

    /// 会话名下面的"任务 · 步骤"（绑着好几件时后面"等 N 件"）：点它回到这件事（项目页，任务浮窗停在这一步）。
    private func path(_ item: LeafTask, count: Int) -> some View {
        Button { workspace.showTask(item.task) } label: {
            Text(Dotted(item.parent?.title, item.task.title, count > 1 ? "等 \(count) 件" : nil))
                .font(Typography.toolbarPath).foregroundStyle(palette.ink3).lineLimit(1)
        }
        .buttonStyle(PressStyle())
        .help("回到这件事")
    }
}

/// "⋯"里会话页的那几项：最上面写所在；绑着的每件没完成的事一项"完成"；"绑定到任务"再绑一件（本项目还没绑会话的叶子任务，
/// 或用会话名新建一个任务绑上）；绑着时"解除绑定"；下面重命名、跳到终端（开在终端里的在线会话）、结束会话。
struct SessionMenuItems: View {
    let state: SessionHeader.State
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let session = state.session
        if let place = state.place { Section { } header: { Text(place) } }
        if let link = state.task {
            let open = link.tasks.filter { $0.task.status != .done }
            ForEach(open) { item in
                Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", systemImage: "checkmark.circle") { workspace.completeTask(item.task.id) }
            }
            Menu("绑定到任务", systemImage: "link") {
                ForEach(link.bindable) { item in
                    Button(Dotted(item.parent?.title, item.task.title).visible) { workspace.attempt { try await workspace.bind(session.sessionID, to: item.task.id) } }
                }
                if !link.bindable.isEmpty { Divider() }
                Button("新建任务并绑定", systemImage: "plus") { workspace.attempt { try await workspace.bindNewTask(to: session) } }
            }
            if link.tasks.count == 1, let item = link.tasks.first {
                Button("解除绑定", systemImage: "link.badge.minus") { unbind(item.task.id) }
            } else if !link.tasks.isEmpty {
                Menu("解除绑定", systemImage: "link.badge.minus") {
                    ForEach(link.tasks) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) { unbind(item.task.id) }
                    }
                }
            }
            Divider()
        }
        if state.canRename {
            Button("重命名…", systemImage: "pencil") { workspace.sessionHeader.rename(state.session) }
        }
        if let id = state.liveID {
            Button("跳到终端窗口", systemImage: "macwindow") { workspace.jumpToTerminal(id) }
        }
        if state.canEnd {
            Button("结束会话", systemImage: "stop.circle", role: .destructive) { workspace.sessionHeader.end(state.session) }
                .disabled(state.ending)
        }
    }

    /// 解除不改会话，也不改任务状态。
    private func unbind(_ task: UUID) { workspace.perform { try await $0.unbindSession(from: task) } }
}
/// 会话绑着的事（含做完了的，先绑的在前）与本项目还能绑的。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    var tasks: [LeafTask]
    var bindable: [LeafTask]

    /// 标题里写的那一件：还没做完的第一件，都做完了是第一件。
    var primary: LeafTask? { tasks.first { $0.task.status != .done } ?? tasks.first }

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        SessionTaskLink(tasks: try store.tasks(boundTo: sessionID), bindable: try store.bindableTasks(in: project))
    }
}

extension Workspace {
    /// 回到会话做的那件事：项目页，任务浮窗停在这一步。
    func showTask(_ task: Card) {
        show(task.projectID.map(Route.project) ?? .unfiled)
        open(task)
    }

    /// 完成会话绑着的任务：完成就是做完了，会话绑着的事都做完了就结束（见 `toggle`）。
    func completeTask(_ id: UUID) {
        attempt { try await self.toggle(id) }
    }
}
#endif
