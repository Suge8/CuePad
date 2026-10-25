#if os(macOS)
import SwiftUI

/// Mac 侧栏最上面的 Cue 名片：头像（大一档，`CueAvatar.Size.header`）、名字与名字右边的新消息数，名字下面一行：
/// 平时是 Cue 此刻（数字账，没有可数的写一句现状、不在时写原因；`CueStatusLine` 的 tally，主窗口里只此一处）；它说了你还没读的话、你又不在 Cue 页上时，
/// 这一行换成它最近说的那句（`CueWatch.lastSaid`，正文墨色，截成一行，同信息、邮件侧栏的预览），读了换回此刻。点开 Cue 页；开着时整张是选中底。
/// 名片永远是这一个高：换页、Cue 说了几行、读没读都不挪下面的进展与项目，Cue 页上也不留空位。
/// 否决过：名片下面挂纸色气泡放最近一句——在 Cue 页上它复述对话，收起就让整列上下跳，淡去留位又空出一块；气泡随话长短变高（Cue 每说一句整列跳一下）。
/// 零件与状态行（`CueStatusRow`：菜单栏面板、输入条、iPad）共用：头像、新消息数、Cue 此刻那一行。
struct CueSidebarCard: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 选中底的圆角：名片比一行高得多，行的小圆角（`RowMetrics.radius`）在这里显得方。
    private static let corner: CGFloat = 18

    var body: some View {
        let cue = workspace.cue
        let selected = workspace.root == .cue
        let said = selected || cue.unread == 0 ? nil : cue.lastSaid
        Button { select(.cue) } label: {
            HStack(spacing: 12) {
                CueEntryAvatar(size: .header)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(cue.name).font(Typography.cueCardName).fontWeight(cue.unread > 0 ? .bold : nil).foregroundStyle(palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        UnreadCount(count: cue.unread).font(Typography.meta)
                    }
                    ZStack(alignment: .leading) {
                        if let said {
                            Text(said).font(Typography.meta).foregroundStyle(palette.ink).lineLimit(1).transition(.handOff)
                        } else {
                            CueStatusLine(tally: true).lineLimit(1).transition(.handOff)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .animation(HandOff.quick, value: cue.unread)
        .animation(HandOff.quick, value: cue.presence)
        .animation(HandOff.quick, value: said)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "当前页" : "")
        .help("和 \(cue.name) 说话")
        // 容器与选中底一样大（行底向两边让出 `RowMetrics.bleed`）：底的四角就是容器的圆角
        .padding(.horizontal, RowMetrics.bleed)
        .rowContainer(.rect(cornerRadius: Self.corner))
        .padding(.horizontal, SidebarMetrics.edge)
    }
}

#endif
