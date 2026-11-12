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

/// 会话条最上一行：选中时 Cue 铺满会话条之外（`Workspace.goHome`），同手机以 Cue 为根。
struct RailCue: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue, selected = workspace.cueHome
        Button { workspace.goHome() } label: {
            RailLine {
                CueAvatar(cue.beat, size: .inline)
            } rest: {
                Text(verbatim: cue.name).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(verbatim: cue.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 会话条上的会话：只有等你的常驻在上面（没有就整组不在），其余的收在各自的项目下面——项目一行写它有几个在推进，点开才列出来。
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
                    VStack(spacing: Spacing.hair) {
                        header(Text(verbatim: TaskBoard.Column.waiting.title), count: rows.waiting.count, ink: TaskBoard.Column.waiting.countInk(palette))
                        ForEach(rows.waiting) { cell($0) }
                    }
                    .transition(.opacity)
                }
                VStack(spacing: Spacing.hair) {
                    Button { workspace.selectPane(.projects) } label: { header(Text("项目"), count: nil, ink: palette.ink3).contentShape(.rect) }
                        .buttonStyle(PressStyle())
                    ForEach(workspace.catalog?.projects ?? []) { project in
                        let sessions = byProject[project.id] ?? []
                        projectRow(project, running: sessions.count)
                        if expanded.contains(project.id) { ForEach(sessions) { cell($0, compact: true) } }
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

    private func cell(_ item: SessionRailRows.Item, compact: Bool = false) -> some View {
        SessionRailCell(item: item, form: .wide, moves: false, selected: marked.contains(item.id), compact: compact, open: open)
            .transition(.opacity)
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

    private func projectRow(_ project: Project, running: Int) -> some View {
        let selected = workspace.mainRoute == .project(project.id) && !workspace.cueHome
        let open = expanded.contains(project.id)
        return Button {
            if selected, running > 0 { expanded.formSymmetricDifference([project.id]) } else {
                workspace.show(.project(project.id))
                if running > 0 { expanded.insert(project.id) }
            }
        } label: {
            RailLine {
                ProjectGlyph(project: project)
            } rest: {
                Text(verbatim: project.shownName).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.item)
                if running > 0 {
                    Circle().fill(palette.signature).frame(width: 6, height: 6)
                    Text(running, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                    Chevron(.forward).foregroundStyle(palette.ink3).rotationEffect(.degrees(open ? 90 : 0))
                }
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(verbatim: project.shownName))
        .accessibilityValue(running > 0 ? Text(running, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

