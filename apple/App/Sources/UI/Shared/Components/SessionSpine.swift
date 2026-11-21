import CueStore
import SwiftUI

struct SessionSpine: View {
    let rows: SessionRailRows
    let open: (SessionState) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var pitch: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tall: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var short: CGFloat = 32
    @State private var phase = DebugHooks.preset.railOpen ? Phase.pinned : .shut
    @State private var hovered: String?
    @State private var pressed: Date?

    private enum Phase { case shut, scrubbing, pinned }

    static let width: CGFloat = 34
    private static let mark: CGFloat = 12
    private static let column = width - 2 * Chrome.pad
    private static let panelWidth: CGFloat = 300
    private static let quietDot: CGFloat = 5
    private static let split = Spacing.group
    private static let tapTime: TimeInterval = 0.3
    private static let tapSlop: CGFloat = 10

    private var expanded: Bool { phase != .shut }

    var body: some View {
        GeometryReader { band in
            let full = Plan(rows, band: band.size, expanded: true, pitch: pitch, tall: tall, short: short)
            let plan = expanded ? full : Plan(rows, band: band.size, expanded: false, pitch: pitch, tall: tall, short: short)
            ZStack(alignment: .leading) {
                if phase == .pinned {
                    Color.clear.contentShape(.rect).ignoresSafeArea().onTapGesture { collapse() }
                        .readerHidden(true)
                }
                if plan.count > 0 { spine(plan, hits: full).padding(.leading, Spacing.tight) }
            }
            .frame(width: band.size.width, height: band.size.height, alignment: .leading)
        }
        .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade, value: expanded)
        .sensoryFeedback(.selection, trigger: hovered) { _, new in new != nil }
        .onChange(of: active) { _, active in if !active { collapse() } }
    }

    private func spine(_ plan: Plan, hits: Plan) -> some View {
        let shape = RoundedRectangle(cornerRadius: expanded ? Radius.sheet : Self.width / 2, style: .continuous)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.waiting) { row($0, plan) }
                if plan.splits { Color.clear.frame(height: Self.split) }
                ForEach(plan.advancing) { row($0, plan) }
                if !plan.hidden.isEmpty {
                    Text(verbatim: "+\(plan.hidden.count)")
                        .font(Typography.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(palette.ink2)
                        .frame(width: Self.column, height: plan.rowHeight)
                        .background { ForEach(plan.hidden, id: \.self) { Color.clear.relaySpot(session: $0, row: .rail) } }
                        .readerHidden(true)
                }
            }
            .padding(Chrome.pad)
            .padding(.vertical, Spacing.tight)
        }
        .scrollDisabled(phase != .pinned)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: plan.width, height: plan.height, alignment: .topLeading)
        // 面板里的空白接住轻点、什么也不做：只有形状没有手势的地方，轻点会穿过去落到下面的对话上（实测）
        .background { if phase == .pinned { Color.clear.contentShape(.rect).onTapGesture {}.readerHidden(true) } }
        .clipShape(shape)
        .rowContainer(shape)
        .glass(in: shape)
        .contentShape(shape)
        .gesture(scrub(hits), isEnabled: phase != .pinned)
        .overlay {
            if !expanded {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(Text("会话"))
                    .accessibilityValue(Text(rows.waiting.count + rows.advancing.count, format: .number))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { phase = .pinned }
            }
        }
        .background {
            if expanded { Button("收起", action: collapse).keyboardShortcut(.cancelAction).hidden() }
        }
        .accessibilityAction(.escape) { collapse() }
    }

    private func row(_ item: SessionRailRows.Item, _ plan: Plan) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 0) {
                mark(item).frame(width: Self.column)
                if expanded {
                    words(item, twoLines: plan.twoLines)
                        .padding(.trailing, Spacing.item)
                        .frame(width: plan.width - Self.column - 2 * Chrome.pad, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .frame(height: plan.rowHeight, alignment: .leading)
        }
        .buttonStyle(RowStyle(selected: hovered == item.id))
        .allowsHitTesting(phase == .pinned)
        // 收着时这一行不进读屏，换成什么都没有：藏起（readerHidden）的话，标在动的那几行照样被列出来（模拟器无障碍树实测）
        .accessibilityRepresentation {
            if expanded {
                Button(item.name) { choose(item) }.accessibilityValue(Dotted(item.shown.label, line(item)).spoken)
            }
        }
        .transition(.opacity)
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

    private func scrub(_ plan: Plan) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard phase != .shut else {
                    pressed = .now
                    phase = .scrubbing
                    return
                }
                hovered = plan.item(at: drag.location)?.id
            }
            .onEnded { drag in
                let tap = Date.now.timeIntervalSince(pressed ?? .now) < Self.tapTime
                    && hypot(drag.translation.width, drag.translation.height) < Self.tapSlop
                if tap {
                    hovered = nil
                    phase = .pinned
                } else if let item = plan.item(at: drag.location) {
                    choose(item)
                } else {
                    collapse()
                }
            }
    }

    private func choose(_ item: SessionRailRows.Item) {
        open(item.session)
        collapse()
    }

    private func collapse() {
        hovered = nil
        phase = .shut
    }

    private struct Plan {
        let waiting: [SessionRailRows.Item]
        let advancing: [SessionRailRows.Item]
        let hidden: [String]
        let rowHeight: CGFloat
        let twoLines: Bool
        let width: CGFloat
        let height: CGFloat

        var count: Int { waiting.count + advancing.count }
        var splits: Bool { !waiting.isEmpty && !advancing.isEmpty }
        private static var edge: CGFloat { Chrome.pad + Spacing.tight }

        init(_ rows: SessionRailRows, band: CGSize, expanded: Bool, pitch: CGFloat, tall: CGFloat, short: CGFloat) {
            let total = rows.waiting.count + rows.advancing.count
            let room = band.height - 2 * Self.edge - (expanded ? 2 * Spacing.item : 0) - (rows.waiting.isEmpty || rows.advancing.isEmpty ? 0 : SessionSpine.split)
            let row = expanded ? min(tall, max(short, room / CGFloat(max(total, 1)))) : pitch
            let fits = Int(room / row)
            let shown = expanded || total <= fits ? total : max(0, fits - 1)
            waiting = Array(rows.waiting.prefix(shown))
            advancing = Array(rows.advancing.prefix(shown - waiting.count))
            hidden = (rows.waiting + rows.advancing).dropFirst(shown).map(\.id)
            rowHeight = row
            twoLines = row >= tall - Spacing.tight
            width = expanded ? min(SessionSpine.panelWidth, band.width - Spacing.tight - Spacing.page) : SessionSpine.width
            let lines = CGFloat(shown + (hidden.isEmpty ? 0 : 1))
            let content = 2 * Self.edge + lines * row + (!waiting.isEmpty && !advancing.isEmpty ? SessionSpine.split : 0)
            height = expanded ? min(content, band.height - 2 * Spacing.item) : content
        }

        func item(at point: CGPoint) -> SessionRailRows.Item? {
            guard point.x <= width, point.y < height else { return nil }
            var y = point.y - Self.edge
            for (index, group) in [waiting, advancing].enumerated() {
                if index == 1, splits { y -= SessionSpine.split }
                if y >= 0, y < CGFloat(group.count) * rowHeight { return group[Int(y / rowHeight)] }
                y -= CGFloat(group.count) * rowHeight
            }
            return nil
        }
    }
}
