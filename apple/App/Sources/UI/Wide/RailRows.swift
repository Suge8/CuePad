import CueStore
import SwiftUI


struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .padding(.horizontal, RowMetrics.bleed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RailLine<Lead: View, Rest: View>: View {
    var height = Chrome.row
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        HStack(spacing: Spacing.item) {
            lead.frame(width: Chrome.icon)
            HStack(spacing: Spacing.glyph) { rest }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .contentShape(.rect)
    }
}

struct RailRow: View {
    let title: LocalizedStringResource
    let icon: Icon
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            RailLine {
                Image(icon).font(Glyph.control).foregroundStyle(palette.signature)
            } rest: {
                Text(title).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)
struct RailIcon: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: Chrome.control, height: Chrome.control)
                .contentShape(.rect)
        }
        .buttonStyle(RowStyle(cell: true))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}
#endif

#if os(macOS)
/// 放在会话条里的都是会话条的一员，不比行首图标重。
struct RailTool: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: ControlSize.compact.height, height: ControlSize.compact.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}
#endif

/// 会话条最上的两格：Cue（选中时它铺满会话条之外，`Workspace.goHome`，同手机以 Cue 为根）与进展。两个最常回的去处并排各占一格，不是两行字，
/// 格里只有一个居中的图形。Cue 那格是它的大头像（不垫圆底：格本身就是它的底；名字在它铺满时的栏头与读屏里），带新消息的点（同收着时右上那颗钮）；
/// 进展那格是加粗的图标，右上角一个数是几件在推进（`CueNow.Tally.moving`，没有就不画）。选中的那格是浮起的纸，另一格是淡底。
/// Cue 那格不写"等你 N"：它数的还有 Cue 自己的提问，紧挨着下面只数会话的"等你"组头，两个数对不上。
struct RailHome: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue, moving = cue.now.tally.moving
        HStack(spacing: Spacing.item) {
            tile(Text(verbatim: cue.name), selected: workspace.cueHome) { workspace.goHome() } content: {
                CueAvatar(cue.beat, size: .card, plate: false).overlay(alignment: .topTrailing) { CueDot().offset(x: 2, y: -2) }
            }
            tile(Text("进展"), selected: workspace.shownPane == .progress) { workspace.selectPane(.progress) } content: {
                Image(.task).font(.system(size: Self.glyph, weight: .semibold)).foregroundStyle(palette.signature)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if moving > 0 {
                            Text(moving, format: .number).font(Typography.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(TaskBoard.Column.advancing.countInk(palette))
                                .padding(Spacing.group)
                        }
                    }
            }
            .accessibilityValue(moving > 0 ? Text("\(moving) 推进中") : Text(verbatim: ""))
        }
        .padding(.horizontal, RowMetrics.bleed)
    }

    private func tile(_ title: Text, selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .modifier(TileSurface(selected: selected))
                .contentShape(.rect(cornerRadius: Radius.sheet))
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 放得下 Cue 的大头像（`CueAvatar.Size.card`）上下各留一档。
    private static let height: CGFloat = 88
    private static let glyph: CGFloat = 30
}

private struct TileSurface: ViewModifier {
    let selected: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if selected {
            content.paper(cornerRadius: Radius.sheet, lifted: true)
        } else {
            content.background(palette.fill, in: .rect(cornerRadius: Radius.sheet, style: .continuous))
        }
    }
}

/// 会话条上的会话：只有等你的常驻在上面（没有就整组不在），其余的收在各自的项目下面——项目一行写它有几个在推进（记号同看板推进中的列头），点开才列出来。
/// 项目多了只列一部分（`shownProjects`）：有会话在推进的、置顶的、此刻开着的一定在，其余按目录的顺序补到 `projectCap` 个，全部在组头去的总览页。
/// 否决过：推进中全部列出（十几行、每行一种状态标，读不过来，看板与 Cue 已经有同一份）；下面的空处填最近结束的会话（栏一直是满的，眼睛没处歇）。
/// 点项目那一行去它的页并展开，再点一次收起；展开着的记在这个窗口里，不存。没归项目的会话算在默认项目下。
struct RailSessions: View {
    let data: SessionRailData
    let marked: Set<String>
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let rows = SessionRailRows(data, pulse: workspace.pulse)
        let byProject = Dictionary(grouping: rows.advancing) { $0.session.projectID ?? Project.defaultID }
        ScrollView {
            VStack(spacing: Chrome.groupGap) {
                if !rows.waiting.isEmpty {
                    VStack(spacing: Spacing.tight) {
                        header(Text(verbatim: TaskBoard.Column.waiting.title), count: rows.waiting.count, ink: TaskBoard.Column.waiting.countInk(palette))
                        ForEach(rows.waiting) { cell($0) }
                    }
                    .transition(.opacity)
                }
                VStack(spacing: Spacing.hair) {
                    projectsHeader
                    ForEach(shownProjects(running: byProject)) { project in
                        let sessions = byProject[project.id] ?? []
                        projectRow(project, running: sessions.count { $0.pulse.tier == .running })
                        if expanded.contains(project.id) { RailProjectSessions(project: project.id, waiting: Set(rows.waiting.map(\.id)), marked: marked, open: open) }
                    }
                }
            }
            .padding(.horizontal, RowMetrics.bleed)
            .safeAreaPadding(.bottom, Chrome.pad)
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade, value: expanded)
            .animation(Motion.fade, value: rows.waiting.map(\.id))
        }
        .scrollIndicators(.hidden)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func cell(_ item: SessionRailRows.Item) -> some View {
        SessionRailCell(item: item, form: .wide, moves: false, selected: marked.contains(item.id), open: open)
            .transition(.opacity)
    }

    private static let projectCap = 7

    private func shownProjects(running: [UUID: [SessionRailRows.Item]]) -> [Project] {
        let all = workspace.catalog?.projects ?? []
        func kept(_ project: Project) -> Bool {
            running[project.id] != nil || project.isPinned || expanded.contains(project.id) || workspace.mainRoute == .project(project.id)
        }
        var room = Self.projectCap - all.count(where: kept)
        return all.filter { project in
            if kept(project) { return true }
            room -= 1
            return room >= 0
        }
    }

    private func header(_ title: Text, count: Int?, ink: Color) -> some View {
        HStack(spacing: Spacing.glyph) {
            title.foregroundStyle(palette.ink3).lineLimit(1)
            if let count { Text(count, format: .number).foregroundStyle(ink).monospacedDigit() }
        }
        .font(Typography.label)
        .padding(.bottom, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: Chrome.groupHeader, alignment: .bottom)
        .accessibilityAddTraits(.isHeader)
    }

    /// 组头就是去项目总览页的那一行：行尾的个数与箭头说它点得进去，悬停、选中同别的行。
    private var projectsHeader: some View {
        let selected = workspace.mainRoute == .shelf && !workspace.cueHome
        return Button { workspace.selectPane(.projects) } label: {
            HStack(spacing: Spacing.glyph) {
                Text("项目").fontWeight(selected ? .semibold : nil).foregroundStyle(selected ? palette.ink : palette.ink3).lineLimit(1)
                Spacer(minLength: 0)
                Text(workspace.catalog?.projects.count ?? 0, format: .number).monospacedDigit().foregroundStyle(palette.ink3)
                Chevron(.forward).foregroundStyle(palette.ink3)
            }
            .font(Typography.label)
            .frame(height: Chrome.row)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? [.isHeader, .isSelected] : .isHeader)
    }

    private func projectRow(_ project: Project, running: Int) -> some View {
        let selected = workspace.mainRoute == .project(project.id) && !workspace.cueHome
        let open = expanded.contains(project.id)
        return Button {
            if selected { expanded.formSymmetricDifference([project.id]) } else {
                workspace.show(.project(project.id))
                expanded.insert(project.id)
            }
        } label: {
            RailLine {
                ProjectGlyph(project: project)
            } rest: {
                Text(verbatim: project.shownName).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.item)
                if running > 0 {
                    BoardLaneMark(column: .advancing, size: 12)
                    Text(running, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                }
                if open || selected { Chevron(.forward).foregroundStyle(palette.ink3).rotationEffect(.degrees(open ? 90 : 0)) }
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .help(running > 0 ? Text("\(running) 推进中") : Text(verbatim: project.shownName))
        .accessibilityLabel(Text(verbatim: project.shownName))
        .accessibilityValue(running > 0 ? Text(running, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 展开的项目下面列的会话，同手机会话列表按项目筛出来的那一份（`SessionListData.read`）：没结束的与置顶的全在（等你的常驻在上面，这里不再列），
/// 再按最近补已结束的到 `cap` 条，多的收在"还有 N 个会话"一行里、点一下多列 `step` 条
/// （同 Codex、Cindy 一个项目先列 5 条，Buzz 列 7 条、每次多 10 条；三家都不让上限藏起在跑的）。
/// 不从会话条那份（`SessionRailData`，Cue 管着的）取：绑在待办或已做完的任务上、还没结束的会话不在那一份里，这里再不列就只剩搜索找得到。
private struct RailProjectSessions: View {
    let project: UUID
    let waiting: Set<String>
    let marked: Set<String>
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var list: SessionListData?
    @State private var extra = 0

    private static let cap = 5
    private static let step = 10

    private struct Reading: Equatable {
        let project: UUID
        let limit: Int
        let moment: Speech.Moment
    }

    var body: some View {
        let live = ((list?.pinned ?? []) + (list?.now ?? [])).filter { !waiting.contains($0.state.sessionID) }
        let ended = (list?.ended ?? []).prefix(max(0, Self.cap - live.count) + extra)
        let hidden = (list?.endedTotal ?? 0) - ended.count
        let items = (live + ended).map { item in
            let pulse = workspace.pulse(of: item), session = pulse.session ?? item.state
            return SessionRailRows.Item(session: session, name: item.task?.title.nonEmpty ?? session.title, pulse: pulse, waiting: nil)
        }
        VStack(spacing: Spacing.hair) {
            ForEach(items) { item in
                SessionRailCell(item: item, form: .wide, moves: false, selected: marked.contains(item.id), compact: true, open: open)
            }
            if hidden > 0 {
                Button { extra += Self.step } label: {
                    RailLine { Color.clear } rest: {
                        Text("还有 \(hidden) 个会话").font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                    .padding(.leading, SessionRailCell.indent)
                }
                .buttonStyle(RowStyle())
            }
        }
        // 引线在项目图形那一列的中线上，从项目那一行往下贯到最后一个会话：看得出这几行归上面那个项目
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.hair).frame(width: 1).padding(.leading, Chrome.icon / 2).padding(.vertical, Spacing.tight)
        }
        .transition(.opacity.combined(with: .offset(y: -Spacing.tight)))
        .observing(services.store, id: Reading(project: project, limit: Self.cap + extra, moment: services.speech), into: $list, onError: workspace.fail) {
            [project, limit = Self.cap + extra, moment = services.speech] store in
            try SessionListData.read(text: "", project: project, historyLimit: limit, at: moment, from: store)
        }
    }
}

extension View {
    /// 数只读 `CueNow.Tally`（同 Cue 的名牌与 App 图标的角标，不另算）。会话条露着时等你那一组就在眼前，不画。
    func railWaitingDot(hidden railHidden: Bool) -> some View { modifier(RailWaitingDot(railHidden: railHidden)) }
}

private struct RailWaitingDot: ViewModifier {
    let railHidden: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 点压在圆的右上角外沿上（圆心约在圆框的内切点）。
    private static let shift: CGFloat = Spacing.hair

    func body(content: Content) -> some View {
        let tally = workspace.cue.now.tally
        let dot: Color? = !railHidden ? nil : tally.asks > 0 ? palette.waiting : tally.reply > 0 ? palette.ink : nil
        content
            .overlay(alignment: .topTrailing) {
                if let dot { StatusDot(color: dot, rim: palette.desk).offset(x: Self.shift, y: -Self.shift).transition(Motion.pop(reduceMotion: reduceMotion)) }
            }
            .animation(Motion.fade, value: dot)
            .accessibilityValue(dot == nil ? Text("") : Text("等你 \(tally.needsYou)"))
    }
}

