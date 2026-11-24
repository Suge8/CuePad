import CueStore
import SwiftUI

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

    static var overhang: CGFloat { (ControlSize.inline.height - Glyph.rowSize) / 2 }
}

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
                Text(verbatim: project.shownName).font(selected ? Typography.bodyBold : Typography.body).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.item)
                if running > 0 {
                    HStack(spacing: Spacing.glyph) {
                        BoardLaneMark(column: .advancing, size: 12)
                        Text(running, format: .number).font(Typography.caption).foregroundStyle(palette.ink3)
                    }
                    .opacity(Self.touch || !hovering ? 1 : 0)
                }
                if Self.touch { Color.clear.frame(width: ControlSize.inline.height * 2 - RailHoverTool.overhang) }
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .contextMenu { ProjectActions(project: project) }
        .help(running > 0 ? Text("\(running) 工作中") : Text(verbatim: project.shownName))
        .accessibilityLabel(Text(verbatim: project.shownName))
        .accessibilityValue(running > 0 ? Text(running, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .leading) {
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
            VStack(spacing: Spacing.hair) {
                ForEach(items) { item in
                    SessionRailCell(item: item, selected: marked.contains(item.id), compact: true, open: open)
                        .transition(.opacity)
                }
            }
            .mask { Rectangle().padding(.horizontal, -RowMetrics.bleed) }
            if list != nil, items.isEmpty, hidden == 0 { fold(.add, Text("新会话")) { workspace.openNewSession(in: project) } }
            if hidden > 0 { fold(.expand, Text("更早的会话"), count: hidden) { withAnimation(motion) { extra += Self.step } } }
            if extra > 0 { fold(.collapse, Text("收起")) { withAnimation(motion) { extra = 0 } } }
        }
        .overlay(alignment: .leading) {
            Capsule().fill(palette.hair).frame(width: 1).padding(.leading, Chrome.icon / 2).padding(.vertical, Spacing.tight)
        }
        .transition(.modifier(active: Curtain(open: false), identity: Curtain(open: true)).combined(with: .opacity))
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
                if let count { Text(count, format: .number) }
            }
            .font(Typography.caption).foregroundStyle(palette.ink3)
        }
        .buttonStyle(RowStyle())
        .padding(.leading, SessionRailCell.indent)
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }
}
