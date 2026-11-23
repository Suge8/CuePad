#if os(macOS)
import SwiftUI

struct CueBarView: View {
    let bar: CueBar?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            CueStatusRow()
                .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
                .glass(in: .rect(cornerRadius: Radius.sheet))
            CueComposer(style: .bar(opens: bar?.opens ?? 0), dismiss: { bar?.hide() }, sent: { bar?.hide() })
        }
        .frame(width: Self.width)
    }

    private static let width: CGFloat = 560
}

struct CueBarTargets: View {
    let targets: [CueBarTarget]
    let aim: CueBarTarget
    let project: UUID
    let pick: (CueBarTarget) -> Void
    let choose: (UUID) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var slot

    var body: some View {
        HStack(spacing: Spacing.item) {
            HStack(spacing: 0) {
                ForEach(targets, id: \.self, content: segment)
            }
            .padding(Spacing.hair)
            .background(palette.fill, in: .capsule)
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: aim)
            Keycap(text: "⇥").help("按 Tab 换去处")
            Spacer(minLength: 0)
            if aim != .cue { DestinationMenu(project: project, choose: choose).transition(.opacity) }
        }
        .animation(Motion.fade, value: aim == .cue)
    }

    private func segment(_ target: CueBarTarget) -> some View {
        let on = target == aim
        return Button { pick(target) } label: {
            HStack(spacing: Spacing.tight) {
                Image(icon(target)).font(Glyph.small).foregroundStyle(on ? palette.signature : palette.ink3)
                Text(title(target)).lineLimit(1)
            }
            .font(Typography.meta.weight(on ? .semibold : .medium))
            .foregroundStyle(on ? palette.ink : palette.ink2)
            .padding(.horizontal, Spacing.group)
            .frame(height: ControlSize.inline.height)
            .background {
                if on {
                    Capsule().fill(palette.dark ? palette.selection : palette.paperLit).overlay(Capsule().strokeBorder(palette.hair))
                        .matchedGeometryEffect(id: "on", in: slot)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func icon(_ target: CueBarTarget) -> Icon {
        switch target {
        case .cue: .cue
        case .idea: .idea
        case .task: .task
        }
    }

    private func title(_ target: CueBarTarget) -> String {
        switch target {
        case .cue: workspace.cue.name
        case .idea: String(localized: "灵感")
        case .task: String(localized: "任务")
        }
    }
}

#endif

import SwiftUI

struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    var status = true
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(unread: workspace.cue.unread)
            row(unread: 0)
        }
        .animation(Motion.fade, value: workspace.cue.unread)
        .animation(Motion.fade, value: workspace.cue.presence)
        .animation(Motion.fade, value: status)
    }

    private func row(unread: Int) -> some View {
        let cue = workspace.cue
        return HStack(spacing: Spacing.item) {
            CueEntryAvatar()
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(cue.name).font(font).fontWeight(cue.unread > 0 ? .bold : nil).foregroundStyle(palette.ink).lineLimit(1)
                if status { CueStatusLine(tally: true).lineLimit(1).transition(.opacity) }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if unread > 0 { UnreadCount(count: unread).font(Typography.meta) }
            trailing
        }
    }
}

struct CueEntryAvatar: View {
    var size = CueAvatar.Size.row
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        CueAvatar(workspace.cue.beat, size: size).relaySpot(cue: .entry)
            .background { CueArrival(color: palette.replied, reach: 1.5) }
    }
}

struct UnreadCount: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            HStack(spacing: Spacing.glyph) {
                StatusDot(color: palette.replied)
                Text(count, format: .number).fontWeight(.semibold).monospacedDigit().contentTransition(.numericText(value: Double(count)))
            }
            .foregroundStyle(palette.replied)
            .fixedSize()
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) 条新消息")
        }
    }
}

struct CueStatusLine: View {
    var tally = false
    var font = Typography.meta
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    var body: some View {
        let cue = workspace.cue
        // 什么都不写时也要有一个真的视图：等同步的那个任务挂在它上面
        ZStack(alignment: .leading) {
            if services.syncing.showsCatchingUp(on: cue.hostID) {
                SyncingLabel().transition(.handOff)
            } else if tally {
                CueLedger(now: cue.now).transition(.handOff)
            } else if case .away(let line, let failed) = cue.now.cue {
                Text(line).foregroundStyle(failed ? palette.failure : palette.ink3).id(line).transition(.handOff)
            } else if let shown {
                SessionShownLabel(shown: shown).transition(.handOff)
            }
        }
        .font(font)
        .transition(.opacity)
        .animation(Motion.fade, value: cue.now)
        .animation(Motion.fade, value: services.syncing.showsCatchingUp(on: cue.hostID))
    }


    private var shown: SessionShown? {
        #if os(macOS)
        workspace.cue.presence.shown?.speaking(workspace.services.cue.keeper?.speech.draft != nil)
        #else
        workspace.cue.presence.shown
        #endif
    }
}

extension CueStatusRow where Trailing == EmptyView {
    init(font: Font = Typography.body.weight(.semibold), status: Bool = true) { self.init(font: font, status: status) { EmptyView() } }
}
