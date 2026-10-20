#if os(macOS)
import SwiftUI

/// Mac 侧栏最上面的 Cue 名片：头像（大一档，`CueAvatar.Size.header`）、名字，名字下面 Cue 此刻那一行（珠子接那一句，不在时写原因；`CueStatusLine` 的 tally，主窗口里只此一处），
/// 名字右边新消息数；下面一个纸色气泡放它最近说的话（`CueWatch.lastSaid`，最多三行，没读的是正文墨色），
/// 左上一个尖角指向头像——是它说的。点开 Cue 页；开着时整张名片是选中底（`RowStyle`），气泡收起：对话就在右边，不重复同一句。
/// 零件与状态行（`CueStatusRow`：菜单栏面板、输入条、iPad）共用：头像、新消息数、Cue 此刻那一行。
struct CueSidebarCard: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 选中底的圆角：名片比一行高得多，行的小圆角（`RowMetrics.radius`）在这里显得方。
    private static let corner: CGFloat = 18

    var body: some View {
        let cue = workspace.cue
        let selected = workspace.page == .cue
        Button { select(.cue) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    CueEntryAvatar(size: .header)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(cue.name).font(Typography.cueCardName).fontWeight(cue.unread > 0 ? .bold : nil).foregroundStyle(palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            UnreadCount(count: cue.unread).font(Typography.meta)
                        }
                        CueStatusLine(tally: true).lineLimit(1)
                    }
                }
                if !selected, let said = cue.lastSaid {
                    SaidBubble(text: said, fresh: cue.unread > 0, tailX: CueAvatar.Size.header.box / 2)
                }
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .animation(Motion.quick, value: cue.unread)
        .animation(Motion.quick, value: cue.presence)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "当前页" : "")
        .help("和 \(cue.name) 说话")
        // 容器与选中底一样大（行底向两边让出 `RowMetrics.bleed`）：底的四角就是容器的圆角
        .padding(.horizontal, RowMetrics.bleed)
        .rowContainer(.rect(cornerRadius: Self.corner))
        .padding(.horizontal, SidebarMetrics.edge)
    }
}

/// 名片里 Cue 最近说的那句：纸色气泡（外形同对话气泡，`BubbleShape`），尾巴从上沿指向头像。
private struct SaidBubble: View {
    let text: String
    let fresh: Bool
    let tailX: CGFloat
    @Environment(\.palette) private var palette

    private static let radius: CGFloat = 20

    var body: some View {
        Text(text)
            .font(Typography.cueCardSaid).lineSpacing(2).lineLimit(3)
            .foregroundStyle(CueStatusLine.said(fresh: fresh, palette))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(palette.paper, in: BubbleShape(tail: BubbleTail(edge: .top, offset: tailX), radius: Self.radius))
            // 尾巴长在矩形外面：让出它的长度，不压到上面的名字
            .padding(.top, BubbleTail.length)
    }
}

#endif
