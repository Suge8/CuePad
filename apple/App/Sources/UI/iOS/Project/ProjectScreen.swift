#if os(iOS)
import CueStore
import SwiftUI

/// 项目页的数据：读取时一并算好上墙用的卡片事实与每张卡的摘要（在 Store 的执行体上，不占主线程）。
nonisolated private struct ProjectPage: Sendable, Equatable {
    var data: ProjectPageData
    var stamps: [CardStamp]
    var entries: [UUID: CardEntry]

    init(_ data: ProjectPageData) {
        self.data = data
        stamps = data.stamps()
        entries = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, CardEntry($0)) })
    }
}

/// 项目页：目标与下一步 → 工作集（置顶在前）→ 更早。与 Mac 同一套上墙规则。
/// 任务纸以下是一个懒加载列表：大项目只创建屏幕内的卡与行。
struct ProjectScreen: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: ProjectPage?
    @State private var expanded: Set<OlderGroup.Period> = []
    /// 任务纸的开合放在页面上：收起其余任务时连带页面的滚动（`TaskFoldAnchor`）。
    @State private var fold = DebugHooks.preset.taskFold
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var board = WallBoard()
    @State private var pi: PiSessionList?

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
        .floatingHeader(project?.name ?? "", detail: detail.isEmpty ? nil : detail) { actions }
        .observing(services.store, id: projectID, into: $page, onError: workspace.fail) {
            [projectID] store in ProjectPage(try ProjectPageData.read(projectID, from: store))
        }
        .observing(services.store, id: PiSessionList.Key(filter: .init(text: "", project: projectID), limit: 0, moment: services.speech), into: $pi, onError: workspace.fail) {
            [projectID, moment = services.speech] store in try PiSessionList.read(text: "", project: projectID, historyLimit: 0, at: moment, from: store)
        }
        .onChange(of: page?.stamps) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
        // 打开时就不在了（iPad 恢复窗口时选回的项目已进回收站）也算：退回书架
        .onChange(of: project == nil, initial: true) { _, gone in if gone { navigation.pop(projectID) } }
    }

    @ViewBuilder
    private func content(_ page: ProjectPage, _ arrangement: WallArrangement) -> some View {
        let data = page.data, lastTarget = data.lastTarget
        // 任务纸不进懒加载栈：纸在懒加载栈的一格里时，收起后按 id 滚回纸底那一行会偏出一屏（`TaskFoldAnchor`）
        VStack(alignment: .leading, spacing: 0) {
            if data.project != nil { FocusCard(data: data, pi: pi, guide: workspace.folderGuide, fold: $fold, position: $position, anchor: anchor).padding(.bottom, Self.sectionGap) }
            // 行距为 0：同一组的"更早"行拼成一张纸（首尾圆角、行间分隔线），段与段之间的距离各自写在段上
            LazyVStack(alignment: .leading, spacing: 0) {
                if data.cards.isEmpty {
                    // 上面已有任务或会话时页面不是空的：空态缩成一行，不放吉祥物与实心主按钮
                    let busy = !data.tasks.roots.isEmpty || pi?.now.isEmpty == false
                    EmptyIdeas(compact: busy, write: newCard).padding(.bottom, busy ? 0 : 24)
                }
                if !arrangement.pinned.isEmpty {
                    // 资料：长期参考的灵感，一行一条压在任务区下面
                    SectionHeader(title: "资料", count: arrangement.pinned.count).padding(.bottom, Self.headerGap)
                    let ids = arrangement.pinned
                    VStack(spacing: 0) {
                        ForEach(ids.compactMap { page.entries[$0] }) { entry in
                            OlderRow(entry: entry, lastTarget: lastTarget[entry.id], isFirst: entry.id == ids.first, isLast: entry.id == ids.last)
                        }
                    }
                    .padding(.bottom, Self.sectionGap)
                }
                if !arrangement.wall.isEmpty {
                    SectionHeader(title: "最近", count: arrangement.wall.count).padding(.bottom, Self.headerGap)
                    wall(arrangement.wall, page: page, lastTarget: lastTarget).padding(.bottom, Self.sectionGap)
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

    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    /// 顶栏的一行："25 条灵感 · 2 项任务 · cuepad"（为 0 的不写；绑定的文件夹只写名字，同名的只写一次，`ProjectFolders.names`）。
    /// 全空的项目没有这一行（只写标题）：页面上的空态已经说了"还没有灵感"，一屏不说两遍。
    private var detail: Dotted {
        let catalog = workspace.catalog
        let count = CountCopy.text((catalog?.cardCounts[projectID] ?? 0, "条灵感"), (catalog?.openTasks[projectID] ?? 0, "项任务"))
        return (count ?? Dotted()) + Dotted(ProjectFolders.names(of: projectID, bindings: catalog?.bindings ?? []))
    }

    private func wall(_ ids: [UUID], page: ProjectPage, lastTarget: [UUID: String]) -> some View {
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: 4, spacing: 12) {
            ForEach(ids.compactMap { page.entries[$0] }) { entry in
                CardTileView(entry: entry, lastTarget: lastTarget[entry.id], floated: board.floated.contains(entry.id))
                    .transition(Motion.item)
            }
        }
    }

    /// 顶栏右边的"⋯"：新建卡片在前，其后是共用的项目操作。
    private var actions: some View {
        Menu("更多", systemImage: "ellipsis") {
            Button("记一条灵感", systemImage: "square.and.pencil", action: newCard)
            if let project {
                Divider()
                ProjectActions(project: project) { navigation.projectForm = .init(project: project) }
            }
        }
    }

    private func newCard() {
        let project = projectID
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            navigation.push(.card(card.id))
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

/// 介绍与任务：项目的一句话介绍在纸外、顶栏下的第一行（次要墨色）；下面总是一张纸：本项目任务（前 3 条没做完的顶层任务连同步骤，
/// 可拖动、缩进，同任务页；没列出的与最近完成的在纸底写个数，点了在纸里原地展开（无回弹弹簧）、各自开合，见 `TaskFold`；收起其余任务时纸底那一行留在原处、位置一步到位、纸上留下的几行淡入，见 `TaskFoldAnchor`；一条都没有时纸里只有一行"添加任务"）+ 本项目此刻在线的 Agent 会话（这一段只回答"现在谁在干活"，
/// 已结束的不列；有历史时末尾"全部 N 个会话"看这个项目的会话列表；没有在线会话时整段不出现，同 Mac 项目页）。项目还没绑文件夹而有同名建议或正在绑时（`FolderGuide.shows`），Agent 段是绑定引导；
/// 没有建议时不占位置，绑定在项目的"⋯"里。三种项目（多、少、只有任务）是同一个结构，切换项目时眼睛不用重新找。
private struct FocusCard: View {
    let data: ProjectPageData
    let pi: PiSessionList?
    let guide: FolderGuide?
    @Binding var fold: TaskFold
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    /// 收起其余任务的次数：每次收起，纸上留下的那几行淡入。
    @State private var collapses = 0
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleTasks = 3
    /// 没做完的任务（含步骤）有这么多时，折起时列出的那几行之后的行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 150ms，模拟器 Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建、淡出再淡入。
    private static let lazyFrom = 20
    /// 收起后纸上留下的那几行淡入多久（同 `Motion.quick`）。
    private static let revealDuration = 0.16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let intro = data.project?.intro {
                Text(intro).font(Typography.secondary).foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .textSelection(.enabled)
            }
            card
        }
        .debugExposesTaskFold { toggle(\.showsAll) }
    }

    /// 还没绑文件夹、而这里该给绑定引导的项目（同名建议或绑定进行中）。
    private var guided: Project? {
        data.project.flatMap { project in
            !workspace.hasFolder(project.id) && guide?.shows(project.id, in: .inset) == true ? project : nil
        }
    }

    private var card: some View {
        // 两段靠段标题与段间距分组，不画分割线
        VStack(alignment: .leading, spacing: 20) {
            // 与任务页同一节奏：行自带 44pt 命中高度，行间不再加间距
            VStack(alignment: .leading, spacing: 0) {
                let roots = data.tasks.roots
                let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
                let done = data.taskCounts.done
                if !roots.isEmpty {
                    Group {
                        SectionLabel(text: "任务", systemImage: "checklist").padding(.bottom, 4)
                        TaskOutline(
                            tree: data.tasks, roots: fold.shown(roots, limit: Self.visibleTasks),
                            lazyAfter: data.tasks.ordered.count >= Self.lazyFrom ? TaskFold.foldedRows(data.tasks, limit: Self.visibleTasks) : nil
                        ) { row in
                            TaskLine(task: row.task, subtasks: data.subtasks[row.id], step: row.depth > 0)
                        }
                    }
                    .keyframeAnimator(initialValue: 1.0, trigger: collapses) { $0.opacity($1) } keyframes: { _ in
                        MoveKeyframe(0.0)
                        LinearKeyframe(1.0, duration: Self.revealDuration)
                    }
                }
                if hidden > 0 || done > 0 {
                    HStack(spacing: 6) {
                        if hidden > 0 { toggleButton(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                        if hidden > 0, done > 0 { Dot() }
                        if done > 0 { toggleButton(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
                    }
                    .font(Typography.secondary).foregroundStyle(palette.ink3)
                    .taskFoldBar(anchor)
                }
                if fold.showsDone {
                    // 同任务页里已完成的行：淡一档，点圆圈回到待办
                    ForEach(data.done) { TaskLine(task: $0) }
                }
                NewTaskLine(project: data.project?.id)
            }
            if let pi, !pi.now.isEmpty, let project = data.project {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Agent", systemImage: "waveform.path.ecg").padding(.bottom, 6)
                    ForEach(pi.now) { item in sessionLine(item) }
                    if pi.total > 0 {
                        Button { navigation.push(.projectSessions(project.id)) } label: {
                            HStack(spacing: 4) {
                                Text("全部 \(pi.now.count + pi.total) 个会话")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                            }
                            .font(Typography.secondary).foregroundStyle(palette.ink3)
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let project = guided {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Agent", systemImage: "waveform.path.ecg").padding(.bottom, 6)
                    ProjectFolderGuide(project: project, guide: guide, style: .inset)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 18)
    }

    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll {
            // 收起是一步到位的（`TaskFoldAnchor`：纸底那一行留在原处，没有能跟着弹簧走的位移），换上来的那几行淡入；减弱动态效果时同样
            collapses += 1
            return anchor.collapse($fold, scrolling: $position)
        }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { fold[keyPath: key].toggle() }
    }

    /// 纸底展开或收起的一格。
    private func toggleButton(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button { toggle(key) } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "已展开" : "已折叠")
    }

    private func sessionLine(_ item: PiSessionListItem) -> some View {
        let session = item.state
        // 项目卡里已经是这个项目：不再写所在
        return Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
            PiSessionRow(session: session, project: nil, delivery: item.delivery, rename: item.rename, undelivered: item.undelivered(at: services.speech)).equatable()
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("看近况、回复")
    }
}
#endif
