#if os(macOS)
import SwiftUI

/// Mac 侧栏最上面的 Cue 名片：头像（大一档，`CueAvatar.Size.header`）、名字，名字下面一行只写此刻在做什么或不在的原因（`CueStatusLine`，不带它最近一句），
/// 名字右边"等你 N"（主窗口里只此一处）与新消息数；下面一个纸色气泡放它最近说的话（`CueWatch.lastSaid`，最多三行，墨色同状态行的那一句），
/// 左上一个尖角指向头像——是它说的。点开 Cue 页；开着时整张名片是选中底（`RowStyle`），气泡收起：对话就在右边，不重复同一句。
/// 零件与状态行（`CueStatusRow`：菜单栏面板、输入条、iPad）共用：头像、等你数、新消息数、状态一行。
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
                            WaitingCount(count: cue.waiting).font(Typography.meta)
                            UnreadCount(count: cue.unread).font(Typography.meta)
                        }
                        CueStatusLine().lineLimit(1)
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
        .animation(Motion.quick, value: cue.waiting)
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

/// 名片里 Cue 最近说的那句：纸色气泡，左上尖角指向头像。
private struct SaidBubble: View {
    let text: String
    let fresh: Bool
    let tailX: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(Typography.cueCardSaid).lineSpacing(2).lineLimit(3)
            .foregroundStyle(CueStatusLine.said(fresh: fresh, palette))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 11).padding(.top, 11 + BubbleShape.tail)
            .background(palette.paper, in: BubbleShape(tailX: tailX))
    }
}

nonisolated private struct BubbleShape: Shape {
    let tailX: CGFloat
    static let tail: CGFloat = 7
    private static let radius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + Self.tail, width: rect.width, height: rect.height - Self.tail),
                        cornerRadius: Self.radius, style: .continuous)
        let apex = rect.minX + tailX
        path.move(to: CGPoint(x: apex - Self.tail, y: rect.minY + Self.tail + 1))
        path.addLine(to: CGPoint(x: apex, y: rect.minY))
        path.addLine(to: CGPoint(x: apex + Self.tail, y: rect.minY + Self.tail + 1))
        path.closeSubpath()
        return path
    }
}
#endif
