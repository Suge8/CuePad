#if os(macOS)
import SwiftUI

/// "对 Cue 说"输入条的内容（`CueBar`）：上面一行头像、名字与 Cue 此刻（`CueStatusRow`），下面是一直展开的输入框（可带图片）。
/// 说出去就收起；草稿与 Cue 页同一份（`CueWatch.draft`），没说完收起了，在 Cue 页里接着写。
struct CueBarView: View {
    /// 调试画面里放在桌面图上拍时没有宿主。
    let bar: CueBar?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CueStatusRow()
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glass(in: .rect(cornerRadius: 22))
            CueComposer(style: .bar(opens: bar?.opens ?? 0)) { bar?.hide() }
        }
        .frame(width: 560)
    }
}

#endif

import SwiftUI

/// 一行 Cue 的现状（菜单栏面板、输入条、iPad 侧栏最上面；Mac 侧栏是名片 `CueSidebarCard`，用同一套零件）：头像（`CueEntryAvatar`）、名字，
/// 下面 Cue 此刻那一行（`CueStatusLine` 的 tally），有新消息的在行尾写几条（石绿，`UnreadCount`；行里放不下时让给那一句）。有新消息时同会话行的"有新回复"：名字加粗。
/// `status` 为假时不写此刻那一行（iPad 上 Cue 页开着时页头已写了这一句）。
struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    var status = true
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 10) {
            CueEntryAvatar()
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(font).fontWeight(cue.unread > 0 ? .bold : nil).foregroundStyle(palette.ink).lineLimit(1)
                if status { CueStatusLine(tally: true).lineLimit(1).transition(.opacity) }
            }
            // 宽度按要紧分：名字与此刻那句先拿（放不下先让出珠子，`CueNowRow`），再是新消息数，余下的才给 Spacer；
            // 行尾的东西（菜单栏面板的额度环与按钮）按自己的宽。都是 0 优先级时那句与 Spacer、新消息数平分剩下的宽，旁边空着也被截成"…"
            .layoutPriority(2)
            Spacer(minLength: 6)
            if cue.unread > 0 {
                // 放不下就不写数（名字已加粗说有新消息），不挤那一句
                ViewThatFits(in: .horizontal) {
                    UnreadCount(count: cue.unread)
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Typography.meta)
                .layoutPriority(1)
            }
            trailing
        }
        .animation(HandOff.quick, value: cue.unread)
        .animation(HandOff.quick, value: cue.presence)
        .animation(HandOff.quick, value: status)
    }
}

/// 去 Cue 的入口上的头像（状态行、Mac 侧栏名片）：接力的 Cue 那一头落在这里（`CueSpot.entry`），又来一句时外面漾开一圈石绿（`CueArrival`）。
struct CueEntryAvatar: View {
    var size = CueAvatar.Size.row
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        CueAvatar(mood: workspace.cue.expression, presence: workspace.cue.presence, size: size).relaySpot(cue: .entry)
            .background { CueArrival(color: palette.replied, reach: 1.5) }
    }
}

/// 新消息有几条（`CueWatch.unread`）：石绿的点与数（有新回复的颜色），没有新的不画。
struct UnreadCount: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            HStack(spacing: 5) {
                Circle().fill(palette.replied).frame(width: CueDot.size, height: CueDot.size)
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

/// Cue 那一行的第二行（`tally`：Mac 侧栏名片、iPad 侧栏、菜单栏面板、输入条与手机、iPad 的页头）或 Mac Cue 页头里此刻在做什么的那一句。
/// `tally` 时就是 Cue 此刻（`CueNowRow`：珠子接那一句，不在时写原因）；不写 tally 时不在写 Cue 此刻的那句原因（`CueNow.Brain.away`，起不来是失败色，其余次要灰），
/// 话在路上、在做事与会话顶栏同一个样子（`PiShownLabel`），空闲不写。
/// Cue 在这台 Mac 值班、正在说回答你的话（`CueKeeper.speech`）时状态词是"输出中"（`PiShown.speaking`）。
/// 它运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`，久过 `Pending.delay` 才出）写"正在同步"：那时写下的状态与数可能已经过时。
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
            // 换一种说法就是换一个视图：先淡掉再淡入（`handOff`）；Cue 此刻里换一句由它自己推上来
            if syncing {
                SyncingLabel().transition(.handOff)
            } else if tally {
                CueNowRow(now: cue.now).transition(.handOff)
            } else if case .away(let line, let failed) = cue.now.cue {
                Text(line).foregroundStyle(failed ? palette.failure : palette.ink3).id(line).transition(.handOff)
            } else if let shown {
                PiShownLabel(shown: shown).id(shown.label).transition(.handOff)
            }
        }
        .font(font)
        .transition(.opacity)
        .animation(HandOff.quick, value: cue.now)
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

/// App 里的 Cue 此刻那一行（`CueNowLine`）：刚做完的那颗到点自己收掉（`Moments` 睡到 `CueNow.nextChange`，不另计时）；
/// 每颗珠子是它那几个会话接力飞光的落点（`relaySpot(bead:)`），露出来的才有，收进"+N"的落回会话与任务行。
struct CueNowRow: View {
    let now: CueNow

    var body: some View {
        Moments(next: now.nextChange(after:)) { date in
            let aged = now.aged(to: date)
            // 窄处（菜单栏面板一行里还有额度环与按钮）先让出珠子：那一句是第一眼要读的，被截成"…"就什么也没说
            ViewThatFits(in: .horizontal) {
                CueNowLine(now: aged) { bead, dot in dot.relaySpot(bead: bead.sessions) }
                CueNowLine(now: aged.withoutBeads)
            }
        }
    }
}

#if os(macOS)
/// Mac Cue 页的页头（窗口工具栏居中，玻璃由工具栏给）：头像，名字接此刻在做什么，一行（Cue 此刻在侧栏的名片上，等你的卡就在输入框上方，这里不写）。输入框里有没说出去的话时头像露"在听"。
/// 只在侧栏收起时有（`PageTitleSlot`）：侧栏开着时最上面的名片已经写了名字与现状。
/// 手机与 iPad 的页头是 `CueHeader`。
struct CueTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 8) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .row)
                .relaySpot(cue: .header)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cue.name).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(font: Typography.toolbarSubtitle).lineLimit(1)
            }
            .padding(.trailing, 14)
        }
        .animation(HandOff.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

extension CueStatusRow where Trailing == EmptyView {
    init(font: Font = Typography.body.weight(.semibold), status: Bool = true) { self.init(font: font, status: status) { EmptyView() } }
}

private extension CueNow {
    /// 只留那一句：窄处让位的那一份（`CueNowRow`）。
    var withoutBeads: CueNow {
        var now = self
        now.beads = []
        now.hidden = 0
        return now
    }
}
