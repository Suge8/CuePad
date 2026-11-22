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
    var leadWidth = Chrome.icon
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        HStack(spacing: Spacing.item) {
            lead.frame(width: leadWidth)
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

struct RailTool: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void

    static var lead: CGFloat { RowMetrics.bleed - (ControlSize.compact.height - Chrome.icon) / 2 }

    var body: some View {
        Button(action: action) { Label { Text(help) } icon: { Image(icon) } }
            .railTool()
            .help(Text(help))
    }
}

extension View {
    /// 侧栏底下那排钮的样子：只画图标，次要字的颜色，按下的底比图标宽一圈；点开菜单的钮（`Menu`）同一个样子。
    func railTool() -> some View { labelStyle(RailToolLabel()).menuStyle(.button).buttonStyle(PressStyle(.button)) }
}

private struct RailToolLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { Face(icon: configuration.icon) }

    private struct Face<Icon: View>: View {
        let icon: Icon
        @Environment(\.palette) private var palette

        var body: some View {
            icon.font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: ControlSize.compact.height, height: ControlSize.compact.height)
                .contentShape(.circle)
        }
    }
}

struct RailHome: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue, moving = cue.now.tally.moving
        HStack(spacing: Spacing.item) {
            tile(Text(verbatim: cue.name), selected: workspace.cueVisible) { workspace.toggleCue() } content: {
                CueAvatar(cue.beat, size: .card, plate: false).relaySpot(cue: workspace.cueVisible ? nil : .entry)
                    .overlay(alignment: .topTrailing) { CueDot().offset(x: 2, y: -2) }
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
            .accessibilityValue(moving > 0 ? Text("\(moving) 工作中") : Text(verbatim: ""))
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

struct RailSessions: View {
    let data: SessionRailData
    let marked: Set<String>
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppServices.self) private var services

    private var expanded: Set<UUID> { services.settings.railOpenProjects }

    private func expand(_ change: (inout Set<UUID>) -> Void) {
        var open = expanded
        change(&open)
        if let live = workspace.catalog?.projects.map(\.id) { open.formIntersection(live) }
        services.settings.railOpenProjects = open
    }

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
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade, value: rows.waiting.map(\.id))
        }
        .scrollIndicators(.hidden)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onChange(of: workspace.mainRoute) { _, route in
            if case .project(let id) = route, !expanded.contains(id) { expand { $0.insert(id) } }
        }
        .onChange(of: marked) { old, new in
            let opened = new.subtracting(old).subtracting(SessionRailRows(data, pulse: workspace.pulse).waiting.map(\.id))
            guard !opened.isEmpty else { return }
            let store = services.store
            workspace.attempt {
                for session in opened {
                    let project = try await store.sessionState(session)?.projectID ?? Project.defaultID
                    if !expanded.contains(project) { expand { $0.insert(project) } }
                }
            }
        }
    }

    private func cell(_ item: SessionRailRows.Item) -> some View {
        SessionRailCell(item: item, selected: marked.contains(item.id), open: open)
            .transition(.asymmetric(insertion: Motion.surface(from: .top, reduceMotion: reduceMotion), removal: .opacity.animation(Motion.yield)))
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

    private var projectsHeader: some View {
        let selected = workspace.mainRoute == .shelf
        return Button { workspace.selectPane(.projects) } label: {
            HStack(spacing: Spacing.glyph) {
                Text("项目").fontWeight(selected ? .semibold : nil).foregroundStyle(selected ? palette.ink : palette.ink3).lineLimit(1)
                Spacer(minLength: 0)
                Text(workspace.catalog?.projects.count ?? 0, format: .number).monospacedDigit().foregroundStyle(palette.ink3)
            }
            .font(Typography.label)
            .frame(height: Chrome.row)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? [.isHeader, .isSelected] : .isHeader)
    }

    private func projectRow(_ project: Project, running: Int) -> some View {
        RailProjectRow(project: project, running: running, selected: workspace.mainRoute == .project(project.id), open: expanded.contains(project.id)) {
            workspace.show(.project(project.id))
            expand { $0.insert(project.id) }
        } toggle: {
            expand { $0.formSymmetricDifference([project.id]) }
        } start: {
            workspace.openNewSession(in: project.id)
        }
    }
}

extension View {
    func railWaitingDot(hidden railHidden: Bool) -> some View { modifier(RailWaitingDot(railHidden: railHidden)) }
}

private struct RailWaitingDot: ViewModifier {
    let railHidden: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

