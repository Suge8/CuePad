import CueStore
import SwiftUI

/// 会话条里悬停才露的小钮（项目行的开合与新会话、会话行的并排、等你卡上的完成）只这一种：同一个大小、墨色与悬停底，
/// 靠行尾的把图形的右沿对到行尾的字上（`overhang`）。原先三处各用各的档，大小、墨色、右沿都不一样。
struct RailHoverTool: View {
    let title: LocalizedStringResource
    let icon: Icon
    let action: () -> Void
    @Environment(\.palette) private var palette

    init(_ title: LocalizedStringResource, _ icon: Icon, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(icon).font(Glyph.small).foregroundStyle(palette.ink2) }
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .inline))
            .help(Text(title))
            .accessibilityLabel(Text(title))
    }

    /// 钮的框比里面的图形每边宽出这么多：靠行尾的往外让出它，图形的右沿正对着行尾的字。
    static var overhang: CGFloat { (ControlSize.inline.height - Glyph.rowSize) / 2 }
}

/// 项目那一行。Mac 上指针停着才露两颗小钮，都叠在行上（钮里不套钮）：行首项目的图形换成开合的箭头（同 Notion、Codex 的侧栏：
/// 箭头就在引线那一列的头上），行尾在推进的数让给加号（在这个项目下开新会话；数在悬停提示里）。平时这一行只有图形、名字与数。
/// 触屏没有悬停：加号与箭头一直画在行尾、各占一格，数排在它们左边。
/// 否决过：箭头与加号都排在行尾（两颗钮挤在一起，数还要让位；箭头展开着、选中时常驻，行与行长得不一样）。
struct RailProjectRow: View {
    let project: Project
    let running: Int
    let selected: Bool
    let open: Bool
    let show: () -> Void
    let toggle: () -> Void
    let start: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: show) {
            RailLine {
                ProjectGlyph(project: project).opacity(Self.touch || !hovering ? 1 : 0)
            } rest: {
                Text(verbatim: project.shownName).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.item)
                if running > 0 {
                    HStack(spacing: Spacing.glyph) {
                        BoardLaneMark(column: .advancing, size: 12)
                        Text(running, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .opacity(Self.touch || !hovering ? 1 : 0)
                }
                if Self.touch { Color.clear.frame(width: ControlSize.inline.height * 2 - RailHoverTool.overhang) }
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .contextMenu { ProjectActions(project: project) }
        .help(running > 0 ? Text("\(running) 推进中") : Text(verbatim: project.shownName))
        .accessibilityLabel(Text(verbatim: project.shownName))
        .accessibilityValue(running > 0 ? Text(running, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .leading) {
            // 箭头的框比图形那一列宽：往左让出多的一半，箭头正在那一列的中线上
            if !Self.touch { fold.opacity(hovering ? 1 : 0).offset(x: (Chrome.icon - ControlSize.inline.height) / 2) }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                RailHoverTool("新会话", .add, action: start)
                if Self.touch { fold }
            }
            .opacity(Self.touch || hovering ? 1 : 0)
            .offset(x: RailHoverTool.overhang)
        }
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        #endif
        .animation(Motion.fade, value: hovering)
    }

    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif

    private var fold: some View {
        Button(action: toggle) {
            Chevron(.forward).foregroundStyle(palette.ink2).rotationEffect(.degrees(open ? 90 : 0))
        }
        .buttonStyle(ControlButtonStyle(kind: .icon, size: .inline))
        .help(open ? Text("收起") : Text("展开"))
        .accessibilityLabel(open ? Text("收起") : Text("展开"))
        .accessibilityValue(Text(verbatim: project.shownName))
    }
}

/// 展开的项目下面列的会话，同手机会话列表按项目筛出来的那一份（`SessionListData.read`）：没结束的与置顶的全在（等你的常驻在上面，这里不再列），
/// 再按最近补已结束的到 `cap` 条，多的收在"更早的会话"一行里（行尾写还有几个）、点一下多列 `step` 条；列多了下面多一行"收起"，回到 `cap` 条。
/// 多列的只记在这一次展开里：项目收起再打开回到 `cap` 条
/// （同 Codex、Cindy 一个项目先列 5 条，Buzz 列 7 条、每次多 10 条；三家都不让上限藏起在跑的）。
/// 不从会话条那份（`SessionRailData`，Cue 管着的）取：绑在待办或已做完的任务上、还没结束的会话不在那一份里，这里再不列就只剩搜索找得到。
struct RailProjectSessions: View {
    let project: UUID
    let waiting: Set<String>
    let marked: Set<String>
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            return SessionRailRows.Item(session: session, name: item.task?.title.nonEmpty ?? session.title, task: item.task, pulse: pulse, waiting: nil)
        }
        let motion = Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade
        VStack(spacing: Spacing.hair) {
            // 行数变了（刚读到、多列一批、收起）这一块连续地长开收回：行在各自的位置上淡入，被下沿一行行露出来，
            // 不让下面往下让的行从还没淡完的字上压过去。只裁上下，左右留给行的悬停底
            VStack(spacing: Spacing.hair) {
                ForEach(items) { item in
                    SessionRailCell(item: item, form: .wide, selected: marked.contains(item.id), compact: true, open: open)
                        .transition(.opacity)
                }
            }
            .mask { Rectangle().padding(.horizontal, -RowMetrics.bleed) }
            // 这个项目下一个会话都没有：展开不留一片空，给开头的那一步
            if list != nil, items.isEmpty, hidden == 0 { fold(.add, Text("新会话")) { workspace.openNewSession(in: project) } }
            if hidden > 0 { fold(.expand, Text("更早的会话"), count: hidden) { withAnimation(motion) { extra += Self.step } } }
            if extra > 0 { fold(.collapse, Text("收起")) { withAnimation(motion) { extra = 0 } } }
        }
        // 引线在项目图形那一列的中线上，从项目那一行往下贯到最后一个会话：看得出这几行归上面那个项目
        .overlay(alignment: .leading) {
            Capsule().fill(palette.hair).frame(width: 1).padding(.leading, Chrome.icon / 2).padding(.vertical, Spacing.tight)
        }
        // 收起：下沿跟着下面的行一起往上收（同一条曲线），不是整块原地淡掉、下面的行从它身上滑过去
        .transition(.modifier(active: Curtain(open: false), identity: Curtain(open: true)).combined(with: .opacity))
        // 读到的带着动画落下：这一组是空着插进来的，不带的话行在展开那一下之后一帧蹦出来
        .observing(services.store, id: Reading(project: project, limit: Self.cap + extra, moment: services.speech), into: $list, animation: motion, onError: workspace.fail) {
            [project, limit = Self.cap + extra, moment = services.speech] store in
            try SessionListData.read(text: "", project: project, historyLimit: limit, at: moment, from: store)
        }
    }

    private struct Curtain: ViewModifier {
        let open: Bool

        func body(content: Content) -> some View {
            content.mask { Rectangle().padding(.horizontal, -RowMetrics.bleed).scaleEffect(y: open ? 1 : 0, anchor: .top) }
        }
    }

    private func fold(_ icon: Icon, _ title: Text, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RailLine(leadWidth: SessionRailCell.mark) {
                Image(icon).font(Glyph.small)
            } rest: {
                title.lineLimit(1)
                Spacer(minLength: Spacing.item)
                if let count { Text(count, format: .number).monospacedDigit() }
            }
            .font(Typography.caption).foregroundStyle(palette.ink3)
        }
        .buttonStyle(RowStyle())
        .padding(.leading, SessionRailCell.indent)
        // 走的时候当场没：多列出来的行就落在它原来那一格，两行字叠着淡一下是花的
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }
}
