import CueStore
import SwiftUI

/// 项目那一行与行尾的两颗小钮：加号在这个项目下开新会话，箭头只管开合；都叠在行尾留出的格上（钮里不套钮）。
/// 箭头展开着、选中或指针停在这一行时才画，加号只在指针停着时画（触屏没有悬停，一直画着）；位置一直留着，露出来时行尾的数不挪。
/// Mac 上在推进的数与加号共用一格：指针停着时数让给加号（数在悬停提示里），不为加号多留一格把名字挤短。
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
                ProjectGlyph(project: project)
            } rest: {
                Text(verbatim: project.shownName).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.item)
                if running > 0 {
                    HStack(spacing: Spacing.glyph) {
                        BoardLaneMark(column: .advancing, size: 12)
                        Text(running, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .opacity(hovering ? 0 : 1)
                }
                Color.clear.frame(width: Self.slots)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .contextMenu { ProjectActions(project: project) }
        .help(running > 0 ? Text("\(running) 推进中") : Text(verbatim: project.shownName))
        .accessibilityLabel(Text(verbatim: project.shownName))
        .accessibilityValue(running > 0 ? Text(running, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .trailing) {
            HStack(spacing: Spacing.hair) {
                if adds { tool(.add, "新会话", action: start).transition(.opacity) }
                fold
            }
            // 钮的圆比留出的那一格宽：往右让出多的一半，箭头正在那一格的中线上
            .offset(x: (ControlSize.inline.height - Chrome.icon) / 2)
        }
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }

    /// 触屏没有悬停：加号一直画着、自己占一格，在推进的数排在它左边不让位。
    #if os(iOS)
    private var adds: Bool { true }
    private static let slots = Chrome.icon + Spacing.hair + ControlSize.inline.height
    #else
    private var adds: Bool { hovering }
    private static let slots = Chrome.icon
    #endif

    private func tool(_ icon: Icon, _ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(icon).font(Glyph.small).foregroundStyle(palette.ink2) }
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .inline))
            .help(Text(title))
            .accessibilityLabel(Text(title))
    }

    private var fold: some View {
        // 触屏没有悬停：一直画着
        #if os(iOS)
        let shown = true
        #else
        let shown = open || selected || hovering
        #endif
        return Button(action: toggle) {
            Chevron(.forward).foregroundStyle(palette.ink3).rotationEffect(.degrees(open ? 90 : 0))
        }
        .buttonStyle(ControlButtonStyle(kind: .icon, size: .inline))
        .opacity(shown ? 1 : 0)
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
    private static let stagger = 0.03

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
            // 依次落下，一行比上一行晚一拍：一整块同时出现读不出是从项目里展开来的。只管入场；收起是整组一起走
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SessionRailCell(item: item, form: .wide, selected: marked.contains(item.id), compact: true, open: open)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -Spacing.item)).animation(motion.delay(Double(min(index, Self.cap)) * Self.stagger)),
                        removal: .opacity))
            }
            if hidden > 0 { fold(.expand, Text("更早的会话"), count: hidden) { extra += Self.step } }
            if extra > 0 { fold(.collapse, Text("收起")) { withAnimation(motion) { extra = 0 } } }
        }
        // 引线在项目图形那一列的中线上，从项目那一行往下贯到最后一个会话：看得出这几行归上面那个项目
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.hair).frame(width: 1).padding(.leading, Chrome.icon / 2).padding(.vertical, Spacing.tight)
        }
        .transition(.opacity.combined(with: .offset(y: -Spacing.tight)))
        // 读到的带着动画落下：这一组是空着插进来的，不带的话行在展开那一下之后一帧蹦出来（收起时内容已在，是顺的）
        .observing(services.store, id: Reading(project: project, limit: Self.cap + extra, moment: services.speech), into: $list, animation: motion, onError: workspace.fail) {
            [project, limit = Self.cap + extra, moment = services.speech] store in
            try SessionListData.read(text: "", project: project, historyLimit: limit, at: moment, from: store)
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
        .transition(.opacity)
    }
}
