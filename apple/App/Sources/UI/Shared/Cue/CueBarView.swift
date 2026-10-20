#if os(macOS)
import SwiftUI

/// "对 Cue 说"输入条的内容（`CueBar`）：上面一行头像、名字与在管、等你（`CueStatusRow`），下面是一直展开的输入框（可带图片）。
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

/// 一行 Cue 的现状（侧栏最上面、菜单栏面板、输入条）：头像、名字，下面"在管 N · 等你 M"（`CueStatusLine` 的 tally），有新消息的在行尾写几条（石绿）。
/// 有新消息时同会话行的"有新回复"：名字加粗，又来一句时头像外漾开一圈石绿（`CueArrival`）。
struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 10) {
            CueAvatar(mood: cue.expression, presence: cue.presence, size: .row).relaySpot(cue: .entry)
                .background { CueArrival(color: palette.replied, reach: 1.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(font).fontWeight(cue.unread > 0 ? .bold : nil).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(tally: true).lineLimit(1)
            }
            Spacer(minLength: 6)
            UnreadCount(count: cue.unread).font(Typography.meta)
            trailing
        }
        .animation(Motion.quick, value: cue.unread)
        .animation(Motion.quick, value: cue.presence)
    }
}

/// 新消息有几条（`CueWatch.unread`）：石绿的点与数（有新回复的颜色），没有新的不画。
private struct UnreadCount: View {
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

/// Cue 那一行的第二行（`tally`：侧栏、菜单栏面板、输入条与手机、iPad 的页头）或 Mac Cue 页头里此刻在做什么的那一句。
/// 不在时写原因（`CuePresence.line`，起不来是失败色，其余次要灰）；`tally` 时其余写"在管 N · 等你 M"（`CueTallyLine`），都为 0 时 Cue 在做事写状态词、
/// 静着写一句安静的现状；不写 tally 时话在路上、在做事与会话顶栏同一个样子（`PiShownLabel`），空闲不写。
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
        let counted = tally && (cue.managing > 0 || cue.waiting > 0)
        // 什么都不写时也要有一个真的视图：等同步的那个任务挂在它上面
        ZStack(alignment: .leading) {
            // 换一句就是换一个视图（按说的字认）：同一种说法里换字也先淡掉再淡入（`handOff`）；数变了原地滚过去
            if syncing {
                SyncingLabel().transition(.handOff)
            } else if let line = cue.presence.line(name: cue.name) {
                Text(line).foregroundStyle(cue.presence.isUnreachable ? palette.failure : palette.ink3).id(line).transition(.handOff)
            } else if counted || (tally && shown == nil) {
                CueTallyLine().id(Self.tallyID).transition(.handOff)
            } else if let shown {
                PiShownLabel(shown: shown).id(shown.label).transition(.handOff)
            }
        }
        .font(font)
        .transition(.opacity)
        .animation(Motion.quick, value: cue.managing)
        .animation(Motion.quick, value: cue.waiting)
        .pending(services.isCatchingUp(on: cue.hostID), shown: $syncing)
    }

    private static let tallyID = "tally"

    private var shown: PiShown? {
        #if os(macOS)
        workspace.cue.presence.shown?.speaking(workspace.services.cue.keeper?.speech.draft != nil)
        #else
        workspace.cue.presence.shown
        #endif
    }
}

/// Cue 那一行的"在管 N · 等你 M"（`TallyLabel`）：在管那半是次要墨色，流光在 Cue 做事时（`CueWatch.busy`）会动。
private struct CueTallyLine: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        TallyLabel(managing: cue.managing, waiting: cue.waiting) { TallyStreak(flowing: cue.busy) } mark: { Image(.waiting) }
            .foregroundStyle(palette.ink2)
    }
}

/// 在管前那一截靛青流光：Cue 在做事时一道光沿着淡的底走（`LoopLayer.sheen`），静着时与减弱动态效果时是静止的样子（`StillStreak`）。
struct TallyStreak: View {
    let flowing: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if flowing, !reduceMotion {
            StillStreak().hidden()
                .background(palette.selection, in: .capsule)
                .overlay { LoopLayer(kind: .sheen, color: palette.signature).clipShape(.capsule) }
                .transition(.opacity)
        } else {
            StillStreak().transition(.opacity)
        }
    }
}

#if os(macOS)
/// Mac Cue 页的页头（窗口工具栏居中，玻璃由工具栏给）：头像，名字接此刻在做什么，一行（在管与等你在侧栏的 Cue 行，等你的卡就在输入框上方，这里不写第三遍）。输入框里有没说出去的话时头像露"在听"。
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
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

extension CueStatusRow where Trailing == EmptyView {
    init(font: Font = Typography.body.weight(.semibold)) { self.init(font: font) { EmptyView() } }
}
