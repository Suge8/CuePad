#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 会话页的页头全在窗口工具栏上：居中的标题（会话名接状态，绑着任务时下面一行是这件事，左边是它的完成圈）与右上"⋯"里的会话操作
/// （所在、完成任务或绑定到任务、重命名、跳到终端、结束会话）。内容区里不再另起一行页头。
/// 工具栏项在主窗口里常驻（`SessionTitleSlot`、`PageMenuSlot`），随页面切换换里面的内容：增删工具栏项会重建整条工具栏，
/// 进出会话页、换会话时那要占点击回合的一半。会话页只把算好的值与动作交到这里；不是会话页时槽里是空的。
@Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        var title: String
        var undelivered: String?
        var ending: Bool
        /// "⋯"最上面写的所在。
        var place: Dotted?
        /// 本机桥上在线、开在终端里的会话（可跳到终端）。
        var liveID: CuePi.PiSession.ID?
        var canEnd: Bool
        var canRename: Bool
        /// 对话在看历史时标题让开。
        var showsHeader: Bool
        /// "⋯"里的菜单项晚于标题两帧建（建菜单约占点击回合的一半）。
        var showsMenu: Bool
        /// 这个会话做的是哪件事；读到前是 nil。
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
/// 绑着任务时玻璃里是提醒事项那样的一条：左边是这件事的完成圈（点它完成，会话随之结束），会话名下面一行小字写"任务 · 步骤"，点它回到这件事。
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
        let session = state.session, task = state.task?.task
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
                if let task { path(task, parent: state.task?.parent) }
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
        .help(done ? "这件事已完成" : "完成任务：打勾，并结束这个会话")
        .accessibilityLabel(done ? "任务已完成" : "完成任务")
    }

    /// 会话名下面的"任务 · 步骤"：点它回到这件事（项目页，任务浮窗停在这一步）。
    private func path(_ task: Card, parent: Card?) -> some View {
        Button { workspace.showTask(task) } label: {
            Text(Dotted(parent?.title, task.title)).font(Typography.toolbarPath).foregroundStyle(palette.ink3).lineLimit(1)
        }
        .buttonStyle(PressStyle())
        .help("回到这件事")
    }
}

/// "⋯"里会话页的那几项：最上面写所在；绑着没完成的任务时"完成任务"，没绑时"绑定到任务"（本项目还没开始的叶子任务，或用会话名新建一个任务绑上）；
/// 下面重命名、跳到终端（开在终端里的在线会话）、结束会话。
struct SessionMenuItems: View {
    let state: SessionHeader.State
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let session = state.session
        if let place = state.place { Section { } header: { Text(place) } }
        if let link = state.task {
            if let task = link.task {
                if task.status != .done {
                    Button("完成任务", systemImage: "checkmark.circle") { workspace.completeTask(task.id) }
                }
            } else {
                Menu("绑定到任务", systemImage: "link") {
                    ForEach(link.bindable) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) { workspace.bind(session.sessionID, to: item.task.id) }
                    }
                    if !link.bindable.isEmpty { Divider() }
                    Button("新建任务并绑定", systemImage: "plus") { workspace.bindNewTask(to: session) }
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
}
/// 会话绑着的任务（和它的上级），没绑时本项目能绑的任务。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    var task: Card?
    var parent: Card?
    var bindable: [BindableTask]

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        let task = try store.task(boundTo: sessionID)
        return SessionTaskLink(
            task: task, parent: try task?.parentID.flatMap { try store.card($0) },
            bindable: task == nil ? try store.bindableTasks(in: project) : [])
    }
}

extension Workspace {
    /// 回到会话做的那件事：项目页，任务浮窗停在这一步。
    func showTask(_ task: Card) {
        show(task.projectID.map(Route.project) ?? .unfiled)
        open(task)
    }

    /// 完成会话绑着的任务：完成就是做完了，会话随之结束（见 `toggle`）。
    func completeTask(_ id: UUID) {
        attempt { try await self.toggle(id) }
    }

    /// 把会话绑到任务上；任务里写好没发的话挪进这个会话的回复框，由你决定发不发。
    func bind(_ sessionID: String, to task: UUID) {
        let store = services.store, settings = services.settings
        attempt {
            if let text = try await store.bindSession(sessionID, to: task) {
                settings.setReplyDraft(ComposerDraft(text: text), for: PiSessionState.recordID(sessionID: sessionID))
            }
        }
    }

    /// 用会话名在会话所在的项目里新建一个任务，绑上。
    func bindNewTask(to session: PiSessionState) {
        let store = services.store, sessionID = session.sessionID, title = session.title, project = session.projectID
        attempt {
            let task = try await self.createTask(title, in: project)
            try await store.bindSession(sessionID, to: task.id)
        }
    }
}
#endif
