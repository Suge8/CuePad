import CueStore
import SwiftUI

struct SessionSpine: View {
    let rows: SessionRailRows
    let open: (SessionState) -> Void
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var pitch: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tall: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var short: CGFloat = 32

    static let width: CGFloat = 34
    private static let mark: CGFloat = 12
    private static let quietDot: CGFloat = 5

    var body: some View {
        EdgeIndex(
            groups: [rows.waiting, rows.advancing], edge: .leading,
            metrics: .init(width: Self.width, pitch: pitch, tall: tall, short: short, panel: 300), shut: .capsule, label: "会话",
            spoken: { ($0.name, Dotted($0.shown.label, line($0)).spoken) }, choose: { open($0.session) },
            mark: { item, _ in mark(item) }, words: { item, cell in words(item, twoLines: cell.twoLines) },
            overflow: { hidden in ForEach(hidden, id: \.self) { Color.clear.relaySpot(session: $0, row: .rail) } })
    }

    private func mark(_ item: SessionRailRows.Item) -> some View {
        ZStack {
            if item.shown.isQuiet { Circle().fill(palette.track).frame(width: Self.quietDot, height: Self.quietDot) }
            StateDot(shown: item.shown, size: Self.mark)
        }
        .relaySpot(session: item.id, row: .rail)
    }

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

    private func line(_ item: SessionRailRows.Item) -> String? { item.waiting == nil ? item.doing : item.ask ?? item.doing }
}
