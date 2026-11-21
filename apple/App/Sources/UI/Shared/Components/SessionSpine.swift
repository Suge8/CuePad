import CueStore
import SwiftUI

/// 手机的会话条：贴屏幕左缘一条玻璃胶囊（边缘索引，`EdgeIndex`），每个会话一颗状态标，等你在上、推进中在下，两组之间一道缝；放不下时排前几个，末尾写 +N。
/// 按住上下滑、轻点、收起与展开见 `EdgeIndex`：松在哪行、点哪行就开哪个会话。
/// 被否决的：60 点宽的格子竖条（每格状态标加名字）——对话、舞台、拍板卡只能在剩下那块里居中，页头与输入框按整屏居中，整页偏右。
struct SessionSpine: View {
    let rows: SessionRailRows
    let open: (SessionState) -> Void
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var pitch: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tall: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var short: CGFloat = 32

    /// 胶囊的宽：状态标那一列加两边的 `Chrome.pad`。
    static let width: CGFloat = 34
    private static let mark: CGFloat = 12
    private static let quietDot: CGFloat = 5

    var body: some View {
        EdgeIndex(
            groups: [rows.waiting, rows.advancing], edge: .leading,
            metrics: .init(width: Self.width, pitch: pitch, tall: tall, short: short, panel: 300), shut: .capsule, label: "会话",
            spoken: { ($0.name, Dotted($0.shown.label, line($0)).spoken) }, choose: { open($0.session) },
            mark: { item, _ in mark(item) }, words: { item, cell in words(item, twoLines: cell.twoLines) },
            // 收在 +N 里的会话，Cue 交给它时光落在这里：它们就在这一格里
            overflow: { hidden in ForEach(hidden, id: \.self) { Color.clear.relaySpot(session: $0, row: .rail) } })
    }

    /// 空闲的会话 `StateDot` 不画东西：垫一颗淡墨小点占着位置，一列数下来几件就是几颗。
    private func mark(_ item: SessionRailRows.Item) -> some View {
        ZStack {
            if item.shown.isQuiet { Circle().fill(palette.track).frame(width: Self.quietDot, height: Self.quietDot) }
            StateDot(shown: item.shown, size: Self.mark)
        }
        .relaySpot(session: item.id, row: .rail)
    }

    /// 放得下两行时名字下面一行写它在做的那句；压矮了就接在名字后面，一行写完。
    private func words(_ item: SessionRailRows.Item, twoLines: Bool) -> some View {
        let name = Text(verbatim: item.name).font(Typography.secondary.weight(.medium))
            .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
        let said = line(item).map { Text(verbatim: $0).font(Typography.caption).foregroundStyle(palette.ink3) }
        return Group {
            if twoLines {
                VStack(alignment: .leading, spacing: Spacing.hair) { name; said }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) { name.layoutPriority(1); said }
            }
        }
        .lineLimit(1)
        .padding(.leading, Spacing.tight)
    }

    /// 它此刻在做什么，等你的写它问你的那句（同宽屏行的悬停提示）。
    private func line(_ item: SessionRailRows.Item) -> String? { item.waiting == nil ? item.doing : item.ask ?? item.doing }
}
