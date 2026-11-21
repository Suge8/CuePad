import CueStore
import SwiftUI

struct SessionRail: View {
    enum Form {
        case phone, wide
        var width: CGFloat? { self == .phone ? SessionRail.phoneWidth : nil }
    }

    static let phoneWidth = Spacing.tight + SessionSpine.width

    enum Opening { case primary, beside }

    let data: SessionRailData
    let form: Form
    var marked: Set<String> = []
    let pulse: (SessionListItem) -> BoardPulse
    let open: (SessionState, Opening) -> Void

    var body: some View {
        Group {
            if form == .phone {
                SessionSpine(rows: SessionRailRows(data, pulse: pulse)) { open($0, .primary) }
            } else {
                SessionRailContent(rows: SessionRailRows(data, pulse: pulse), marked: marked, open: open)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

private struct SessionRailContent: View {
    let rows: SessionRailRows
    let marked: Set<String>
    let open: (SessionState, SessionRail.Opening) -> Void

    @Environment(\.relayStage) private var stage
    @Environment(\.pageActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = SessionRailReveal()
    @Namespace private var moves

    var body: some View {
        GeometryReader { geometry in
            let waitingIdeal = idealHeight(rows.waiting), waitingCap = geometry.size.height * (rows.advancing.isEmpty ? 1 : 0.5)
            let waitingHeight = min(waitingIdeal, waitingCap)
            let advancingRoom = geometry.size.height - (rows.waiting.isEmpty ? 0 : waitingHeight + Chrome.groupGap)
            VStack(spacing: Chrome.groupGap) {
                if !rows.waiting.isEmpty {
                    group(rows.waiting, column: .waiting, overflows: waitingIdeal > waitingCap)
                        .frame(height: waitingHeight)
                }
                if !rows.advancing.isEmpty {
                    group(rows.advancing, column: .advancing, overflows: idealHeight(rows.advancing) > advancingRoom)
                        .frame(maxHeight: idealHeight(rows.advancing))
                }
                if rows.waiting.isEmpty, rows.advancing.isEmpty { SessionRailEmpty() }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade, value: [rows.waiting.map(\.id), rows.advancing.map(\.id)])
        }
        .onChange(of: [rows.waiting.map(\.id), rows.advancing.map(\.id)], initial: true) { _, groups in reveal.update(groups) }
        .onChange(of: active, initial: true) { _, active in reveal.active = active }
        .onAppear { stage?.register(reveal); reveal.active = active }
        .onDisappear { reveal.active = false }
    }

    private var cellGap: CGFloat { Spacing.hair }

    private func rowHeight(_ item: SessionRailRows.Item) -> CGFloat {
        item.waiting == nil ? Chrome.row : Chrome.tallRow
    }

    private func idealHeight(_ items: [SessionRailRows.Item]) -> CGFloat {
        Chrome.groupHeader + items.map(rowHeight).reduce(0, +) + CGFloat(max(0, items.count - 1)) * cellGap + Chrome.pad
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, overflows: Bool) -> some View {
        VStack(spacing: 0) {
            SessionRailHeader(column: column, count: items.count)
                .frame(height: Chrome.groupHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: cellGap) {
                        ForEach(items) { item in
                            SessionRailCell(item: item, selected: marked.contains(item.id), open: open)
                                .frame(height: rowHeight(item))
                                .matchedGeometryEffect(id: item.id, in: moves)
                                .id(item.id)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, RowMetrics.bleed)
                    .scrollTargetLayout()
                    .safeAreaPadding(.bottom, overflows ? Chrome.scrollFade : Chrome.pad)
                }
                .scrollIndicators(.hidden)
                .modifier(BottomFade(on: overflows))
                .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade, value: items.map(\.id))
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { reveal.busy.remove(column) } else { reveal.busy.insert(column) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 1) { reveal.visible[column] = Set($0) }
                .onAppear {
                    reveal.register(column) { id in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onDisappear { reveal.remove(column) }
            }
        }
    }
}

private struct SessionRailHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.glyph) {
            Text(column.title).foregroundStyle(palette.ink3).lineLimit(1)
            tally
        }
        .font(Typography.label)
        .padding(.horizontal, RowMetrics.bleed)
        .padding(.bottom, Spacing.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: some View {
        Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
    }
}

/// 要滚的一组下沿淡出一截：遮罩只在要滚时挂（挂着的遮罩每一帧都要离屏合成一遍，放得下的组不付这笔）。
private struct BottomFade: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Chrome.scrollFade)
                }
            }
        } else {
            content
        }
    }
}

private struct SessionRailEmpty: View {
    @Environment(\.palette) private var palette

    var body: some View {
        RailLine {
            Color.clear
        } rest: {
            Text("没有在推进的会话").font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
        }
        .padding(.horizontal, RowMetrics.bleed)
        .transition(.opacity)
    }
}
