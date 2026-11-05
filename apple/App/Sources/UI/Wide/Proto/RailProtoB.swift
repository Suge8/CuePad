import CueStore
import SwiftUI

/// B 状态环（Arc、Raycast 一路）：每个会话是一枚带状态环的头像，收起时就是一列环。
/// - 头像是会话归处的项目图形（项目色，同看板卡上那颗），环是此刻的状态：在跑靛青一段弧绕圈走（`LoopLayer.halo`）、
///   拍板赭黄整圈外扩一圈波纹、待回复墨色整圈、出错与上下文快满胭脂、有新回复石绿、歇着一圈淡轨道（项目图形也淡成墨）。
/// - 名字下面一行淡字：状态词 · 待了多久（· 上下文快满时的百分比）；要你管的状态词着状态色，在跑的不着色（满屏靛青会压过真在动的环）。
/// - 组头是小号组名，计数靠右；收起时组头只留空：环已经说了谁在等你。
/// - 顶上的搜索展开时长成一条纸色搜索框（`ProtoSearchField`）。
struct RailProtoB: View {
    let rows: SessionRailRows
    let wide: Bool
    let marked: Set<String>

    var body: some View {
        RailProtoGroups(rows: rows, wide: wide, marked: marked, height: { _ in Chrome.tallRow }) { column, count in
            HeaderB(column: column, count: count, wide: wide)
        } row: { item, moves, selected in
            RowB(item: item, wide: wide, selected: selected, moves: moves)
        }
    }
}

private struct HeaderB: View {
    let column: TaskBoard.Column
    let count: Int
    let wide: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide, height: Chrome.groupHeader) {
            Color.clear
        } rest: {
            Text(column.title).foregroundStyle(palette.ink3)
            Spacer(minLength: 0)
            Text(count, format: .number).foregroundStyle(column.countInk(palette))
        }
        .font(Typography.label.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RowB: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool
    let moves: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide, height: Chrome.tallRow) {
            StatusAvatar(item: item, moves: moves)
        } rest: {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: item.session.title)
                    .font(Typography.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
                meta.font(Typography.caption)
            }
            .lineLimit(1)
        }
    }

    private var meta: some View {
        let shown = item.shownState
        return HStack(spacing: Spacing.tight) {
            if item.waiting == nil, case .context(let meter) = item.pulse.word {
                ContextFact(meter: meter)
            } else {
                Text(shown.label).fontWeight(item.needsYou ? .semibold : .regular)
                    .foregroundStyle(item.needsYou ? shown.labelTint(palette) : palette.ink3)
            }
            if shown.clock != nil { Dot().foregroundStyle(palette.ink3); ProtoTime(item: item) }
        }
    }
}

/// 带状态环的头像：环的颜色与动只按会话此刻的状态（`PiShown`、`BoardPulse` 的档），里面是项目图形。
private struct StatusAvatar: View {
    let item: SessionRailRows.Item
    let moves: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var loops

    /// 环的线宽占直径的比例（Mac 约 2.2 点）：比项目图形的笔画略粗，收起时一列环也读得出颜色。
    private static let ringShare: CGFloat = 0.08
    /// 波纹从框的内切圆扩到 1.6 倍（`LoopLayer.ripple`）：框按它缩，扩到头正好一格宽，不被行裁成方块。
    private static let rippleGrowth: CGFloat = 1.6

    var body: some View {
        let line = Chrome.avatar * Self.ringShare
        ZStack {
            Circle().fill(palette.paper).padding(line + Spacing.hair)
            Image(ProjectGlyph.icon(item.project)).font(Glyph.row)
                .foregroundStyle(item.resting ? palette.ink3 : item.project.map { palette.project($0.color) } ?? palette.ink2)
            ring(line)
        }
        .frame(width: Chrome.avatar, height: Chrome.avatar)
        .background {
            if item.waiting == .asking, loops {
                LoopLayer(kind: .ripple, color: palette.waiting).frame(width: Chrome.control / Self.rippleGrowth, height: Chrome.control / Self.rippleGrowth)
            }
        }
        .animation(Motion.fade, value: item.shownState)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func ring(_ line: CGFloat) -> some View {
        if item.waiting == nil, item.pulse.tier == .running {
            if loops && moves {
                LoopLayer(kind: .halo, color: palette.signature)
            } else {
                Circle().stroke(palette.track, lineWidth: line)
                    .overlay { Circle().trim(from: 0, to: 0.3).stroke(palette.signature, style: StrokeStyle(lineWidth: line, lineCap: .round)).rotationEffect(.degrees(-90)) }
                    .padding(line / 2)
            }
        } else {
            Circle().stroke(color, lineWidth: line).padding(line / 2)
        }
    }

    private var color: Color {
        if let waiting = item.waiting { return PiShown(status: waiting).tint(palette) }
        return item.pulse.tier == .needsYou ? item.pulse.tint(palette) : palette.track
    }
}
