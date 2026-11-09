#if os(macOS)
import SwiftUI

/// 草稿与 Cue 页同一份（`CueWatch.draft`）：没说完收起了，在 Cue 页里接着写。
struct CueBarView: View {
    /// 调试画面里放在桌面图上拍时没有宿主。
    let bar: CueBar?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            CueStatusRow()
                .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
                .glass(in: .rect(cornerRadius: Radius.sheet))
            CueComposer(style: .bar(opens: bar?.opens ?? 0)) { bar?.hide() }
        }
        .frame(width: Self.width)
    }

    private static let width: CGFloat = 560
}

#endif

import SwiftUI

/// `status` 为假时不写此刻那一行（iPad 上 Cue 页开着时页头已写了这一句）。
struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    var status = true
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        // 新消息数只在整行连它都排得下时写（名字已加粗说有新消息）；排不下就整行不带它，宽度先给名字与数字账
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
            // 两边已有行距，空白不再另占宽
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

/// Cue 运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`，久过 `Pending.delay` 才出）写"正在同步"：那时写下的状态与数可能已经过时。
struct CueStatusLine: View {
    var tally = false
    var font = Typography.meta
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var syncing = false

    var body: some View {
        let cue = workspace.cue
        // 什么都不写时也要有一个真的视图：等同步的那个任务挂在它上面
        ZStack(alignment: .leading) {
            if syncing {
                SyncingLabel().transition(.handOff)
            } else if tally {
                CueLedger(now: cue.now).transition(.handOff)
            } else if case .away(let line, let failed) = cue.now.cue {
                Text(line).foregroundStyle(failed ? palette.failure : palette.ink3).id(line).transition(.handOff)
            } else if let shown {
                PiShownLabel(shown: shown).id(shown.label).transition(.handOff)
            }
        }
        .font(font)
        .transition(.opacity)
        .animation(Motion.fade, value: cue.now)
        .pending(services.isCatchingUp(on: cue.hostID), shown: $syncing)
    }


    private var shown: PiShown? {
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
