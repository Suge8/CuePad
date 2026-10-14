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
            CueAvatar(mood: cue.mood(), presence: cue.presence, size: .row)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(font).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(fallback: cue.digest.lastSaid).lineLimit(1)
            }
            Spacer(minLength: 6)
            WaitingCount(count: cue.digest.waiting.count).font(Typography.meta)
            trailing
        }
        .animation(Motion.quick, value: cue.digest)
    }
}

/// Cue 此刻在做什么的那一句：话在路上、在做事与会话顶栏同一个样子（`PiShownLabel`）；不在时写原因（`CuePresence.line`，起不来是失败色，其余次要灰）；
/// 都没有时是 `fallback`。页头与状态行同用。
struct CueStatusLine: View {
    var fallback: String?
    var font = Typography.meta
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        Group {
            if let shown = cue.presence.shown {
                PiShownLabel(shown: shown)
            } else if let line = cue.presence.line(name: cue.name) ?? fallback {
                Text(line).foregroundStyle(cue.presence.isUnreachable ? palette.failure : palette.ink3)
            }
        }
        .font(font)
        .transition(.opacity)
    }
}

/// Cue 页的页头，一直在（Mac 窗口工具栏居中、手机顶栏、iPad 面板顶上；玻璃由放它的地方给）：头像，名字与此刻在做什么。
/// 排法同会话页的顶栏：Mac 一行（名字接状态），手机两行；左边让头像贴着玻璃的圆头。输入框里有没说出去的话时头像露"在听"。
struct CueTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 8) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .row)
                #if os(iOS)
                .padding(.leading, 4)
                #endif
            #if os(macOS)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cue.name).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(font: Typography.toolbarSubtitle).lineLimit(1)
            }
            .padding(.trailing, 14)
            #else
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(font: .caption).lineLimit(1)
            }
            .padding(.trailing, 16)
            #endif
        }
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension CueStatusRow where Trailing == EmptyView {
    init(font: Font = Typography.body.weight(.semibold)) { self.init(font: font) { EmptyView() } }
}
