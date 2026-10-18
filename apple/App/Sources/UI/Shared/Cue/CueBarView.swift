#if os(macOS)
import SwiftUI

/// "对 Cue 说"输入条的内容（`CueBar`）：上面一行头像、名字与此刻在做什么（有等你的写"等你 N"），下面是一直展开的输入框（可带图片）。
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

/// 一行 Cue 的现状（侧栏最上面、菜单栏面板、输入条）：头像、名字、此刻在做什么或它最近一句，有等你的写"等你 N"（赭黄）。
struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 10) {
            CueAvatar(mood: cue.mood(), presence: cue.presence, size: .row).relaySpot(cue: .entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(font).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(fallback: cue.lastSaid).lineLimit(1)
            }
            Spacer(minLength: 6)
            WaitingCount(count: cue.waiting).font(Typography.meta)
            trailing
        }
        .animation(Motion.quick, value: cue.waiting)
        .animation(Motion.quick, value: cue.lastSaid)
        .animation(Motion.quick, value: cue.presence)
    }
}

/// Cue 此刻在做什么的那一句：话在路上、在做事与会话顶栏同一个样子（`PiShownLabel`）；不在时写原因（`CuePresence.line`，起不来是失败色，其余次要灰）；
/// 都没有时是 `fallback`。页头与状态行同用。Cue 在这台 Mac 值班、正在说回答你的话（`CueKeeper.speech`）时说"输出中"（`PiShown.speaking`）。
/// 它住在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`，久过 `Pending.delay` 才出）写"正在同步"：那时写下的状态可能已经过时。
struct CueStatusLine: View {
    var fallback: String?
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
                SyncingLabel().transition(Self.handOff)
            } else if let shown {
                PiShownLabel(shown: shown).transition(Self.handOff)
            } else if let line = cue.presence.line(name: cue.name) ?? fallback {
                Text(line).foregroundStyle(cue.presence.isUnreachable ? palette.failure : palette.ink3).transition(Self.handOff)
            }
        }
        .font(font)
        .transition(.opacity)
        .pending(services.isCatchingUp(on: cue.hostID), shown: $syncing)
    }

    /// 换一种说法时旧的先淡掉、新的随后淡入：长短不同的两句在同一处交叉淡，中间几帧叠成读不出的一团。
    private static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.quick.delay(Motion.handOff)), removal: .opacity.animation(.easeOut(duration: Motion.handOff)))

    private var shown: PiShown? {
        #if os(macOS)
        workspace.cue.presence.shown?.speaking(workspace.services.cue.keeper?.speech.draft != nil)
        #else
        workspace.cue.presence.shown
        #endif
    }
}

#if os(macOS)
/// Mac Cue 页的页头（窗口工具栏居中，玻璃由工具栏给）：头像，名字接此刻在做什么，一行（"等你 N"在侧栏的 Cue 行，等你的卡就在输入框上方，这里不写第三遍）。输入框里有没说出去的话时头像露"在听"。
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
