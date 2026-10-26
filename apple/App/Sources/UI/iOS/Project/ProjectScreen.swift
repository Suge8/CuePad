#if os(iOS)
import CueStore
import SwiftUI

/// 项目页的数据：读取时一并算好每张卡的摘要（在 Store 的执行体上，不占主线程）；上墙用的卡片事实在 `ProjectPageData.stamps`。
nonisolated private struct ProjectPage: Sendable, Equatable {
    var data: ProjectPageData
    var entries: [UUID: CardEntry]

    init(_ data: ProjectPageData) {
        self.data = data
        entries = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, CardEntry($0)) })
    }
}

/// 项目页：任务纸 → 置顶的灵感 → 最近（卡片墙）→ 更早，与 Mac 同构、同一套上墙规则；一条灵感都没有时墙上只有"记一条灵感"那一格（`EmptyWallTile`）。
/// 任务纸以下是一个懒加载列表：大项目只创建屏幕内的卡与行。
struct ProjectScreen: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.headerHost) private var headerHost
    @State private var page: ProjectPage?
    @State private var expanded: Set<OlderGroup.Period> = []
    /// 任务纸的开合放在页面上：收起其余任务时连带页面的滚动（`TaskFoldAnchor`）。
    @State private var fold = DebugHooks.preset.taskFold
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var board = WallBoard()

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                if let page, let arrangement = board.arrangement {
                    content(page, arrangement)
                }
                Color.clear.frame(height: 0).debugScrollsToOlder(proxy, ready: board.arrangement != nil)
            }
        }
        .scrollPosition($position)
        .taskFoldScroll(anchor)
        // 顶栏第二行是项目的一句介绍接它的文件夹（`ProjectPlace`）；页顶不写标题时（iPad 侧栏在旁边）这两样另起一行排在页里（`ProjectIntroLine`）
        .floatingHeader(.verbatim(project?.shownName ?? ""), detail: { ProjectIntroLine(project: project, inHeader: true) }, trailing: { actions })
        .observing(services.store, id: projectID, into: $page, onError: workspace.fail) {
            [projectID] store in ProjectPage(try ProjectPageData.read(projectID, from: store))
        }
        .onChange(of: page?.data.stamps) { rearrange() }
        .onDayChange { rearrange() }
        // 打开时就不在了（iPad 恢复窗口时选回的项目已进回收站）也算：退回书架
        .onChange(of: project == nil, initial: true) { _, gone in if gone { workspace.pop(projectID) } }
    }

    @ViewBuilder
    private func content(_ page: ProjectPage, _ arrangement: WallArrangement) -> some View {
        let data = page.data, lastTarget = data.lastTarget
        // 任务纸不进懒加载栈：纸在懒加载栈的一格里时，收起后按 id 滚回纸底那一行会偏出一屏（`TaskFoldAnchor`）
        VStack(alignment: .leading, spacing: 0) {
            if headerHost.namesPage { ProjectIntroLine(project: project).padding(.leading, 4).padding(.bottom, 12) }
            if data.project != nil { FocusCard(data: data, fold: $fold, position: $position, anchor: anchor).padding(.bottom, Self.sectionGap) }
            // 行距为 0：同一组的"更早"行拼成一张纸（首尾圆角、行间分隔线），段与段之间的距离各自写在段上
            LazyVStack(alignment: .leading, spacing: 0) {
                if data.cards.isEmpty {
                    wall { EmptyWallTile() }
                }
                if !arrangement.pinned.isEmpty {
                    // 置顶的灵感：长期参考的，一行一条压在任务纸下面；不另起组名，行首的图钉认得出
                    let ids = arrangement.pinned
                    VStack(spacing: 0) {
                        ForEach(ids.compactMap { page.entries[$0] }) { entry in
                            OlderRow(entry: entry, lastTarget: lastTarget[entry.id], isFirst: entry.id == ids.first, isLast: entry.id == ids.last, pinned: true)
                        }
                    }
                    .padding(.bottom, Self.sectionGap)
                }
                if !arrangement.wall.isEmpty {
                    SectionHeader(title: "最近", count: arrangement.wall.count).padding(.bottom, Self.headerGap)
                    wall {
                        ForEach(arrangement.wall.compactMap { page.entries[$0] }) { entry in
                            CardTileView(entry: entry, lastTarget: lastTarget[entry.id], floated: board.floated.contains(entry.id))
                                .transition(.opacity)
                        }
                    }
                    .padding(.bottom, Self.sectionGap)
                }
                if !arrangement.older.isEmpty {
                    let groups = data.olderGroups(arrangement)
                    let titled = OlderGroup.needsTitles(in: groups)
                    // 有组标题时由组标题自己与段标题隔开
                    SectionHeader(title: "更早", count: arrangement.older.count).id(ScrollAnchor.older).padding(.bottom, titled ? 0 : Self.headerGap)
                    ForEach(groups, id: \.period) { group in
                        if titled { OlderGroupHeader(group: group, expanded: $expanded) }
                        if !group.isMonth || expanded.contains(group.period) {
                            let ids = group.cards
                            ForEach(ids, id: \.self) { id in
                                if let entry = page.entries[id] {
                                    OlderRow(entry: entry, lastTarget: lastTarget[id], isFirst: id == ids.first, isLast: id == ids.last)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    /// 段与段之间、段标题与它的内容之间的距离（书架、Mac 项目页同一节奏）。
    private static let sectionGap: CGFloat = 24
    private static let headerGap: CGFloat = 8
    private static let wallSpacing: CGFloat = 12

    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    /// 卡片墙：辅助字号下只排一列，卡上的字与"记一条灵感"才不被窄列挤成一字一行。
    private func wall(@ViewBuilder _ tiles: () -> some View) -> some View {
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: typeSize.isAccessibilitySize ? 1 : 4, spacing: Self.wallSpacing) { tiles() }
    }

    /// 顶栏右边的"⋯"：新建卡片、看这个项目的会话（进展页两段共用的项目范围设成它，再切到会话段），其后是共用的项目操作。
    private var actions: some View {
        Menu("更多", icon: .more) {
            Button("记一条灵感", icon: .write, action: workspace.newCard)
            Button("看这个项目的会话", icon: .session) {
                workspace.projectScope = projectID
                workspace.showSessions()
            }
            if let project {
                Divider()
                ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
            }
        }
    }

    private func rearrange() {
        guard let data = page?.data else { return }
        var next = board
        if next.refresh(with: data, project: projectID) {
            board = next
        } else {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { board = next }
        }
    }
}

/// 顶栏下总是一张纸（同 Mac 项目页）：本项目任务（前 3 条没做完的顶层任务连同子任务，可拖动、缩进，同进展页）；纸底一行左边"添加任务"，
/// 右边是没列出的与最近完成的个数，点了在纸里原地展开（无回弹弹簧）、各自开合，见 `TaskFold`、`TaskFoldAnchor`。
/// 会话不在页上，"⋯"里"看这个项目的会话"去进展页的会话段。三种项目（多、少、只有任务）是同一个结构，切换项目时眼睛不用重新找。
private struct FocusCard: View {
    let data: ProjectPageData
    @Binding var fold: TaskFold
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    /// 收起其余任务的次数：每次收起，纸上留下的那几行淡入。
    @State private var collapses = 0
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let visibleTasks = 3
    /// 没做完的任务（含子任务）有这么多时，折起时列出的那几行之后的行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 150ms，模拟器 Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建、淡出再淡入。
    private static let lazyFrom = 20
    /// 收起后纸上留下的那几行淡入多久（同 `HandOff.quick`）。
    private static let revealDuration = 0.16

    var body: some View {
        // 与进展页同一节奏：行自带 44pt 命中高度，行间不再加间距
        VStack(alignment: .leading, spacing: 0) {
            let roots = data.tasks.roots
            let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
            let done = data.taskCounts.done
            if !roots.isEmpty {
                TaskOutline(
                    tree: data.tasks, roots: fold.shown(roots, limit: Self.visibleTasks),
                    lazyAfter: data.tasks.ordered.count >= Self.lazyFrom ? TaskFold.foldedRows(data.tasks, limit: Self.visibleTasks) : nil
                ) { row in
                    TaskLine(task: row.task, subtasks: data.subtasks[row.id], step: row.depth > 0)
                }
                .keyframeAnimator(initialValue: 1.0, trigger: collapses) { $0.opacity($1) } keyframes: { _ in
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: Self.revealDuration)
                }
            }
            if fold.showsDone {
                // 同进展页里已完成的行：淡一档，点圆圈回到待办
                ForEach(data.done) { TaskLine(task: $0) }
            }
            // 辅助字号下开合挪到"添加任务"下面一行：并排时输入框会被挤没
            let bar = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0)) : AnyLayout(HStackLayout(spacing: 6))
            bar {
                NewTaskLine(project: data.project?.id)
                Group {
                    if hidden > 0 { toggleButton(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                    if hidden > 0, done > 0 { Dot() }
                    if done > 0 { toggleButton(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3).fixedSize()
            }
            .taskFoldBar(anchor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 18)
        .debugExposesTaskFold { toggle(\.showsAll) }
    }

    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll {
            // 收起是一步到位的（`TaskFoldAnchor`：纸底那一行留在原处，没有能跟着弹簧走的位移），换上来的那几行淡入；减弱动态效果时同样
            collapses += 1
            return anchor.collapse($fold, scrolling: $position)
        }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { fold[keyPath: key].toggle() }
    }

    private func toggleButton(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button { toggle(key) } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(open ? .collapse : .expand).font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}
#endif
