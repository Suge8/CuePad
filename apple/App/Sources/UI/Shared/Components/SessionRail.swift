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
    @Environment(\.palette) private var palette
    @State private var reveal = SessionRailReveal()
    @Namespace private var moves

    var body: some View {
        GeometryReader { geometry in
            let waitingIdeal = idealHeight(rows.waiting), waitingCap = geometry.size.height * (rows.advancing.isEmpty ? 1 : 0.5)
            let waitingHeight = min(waitingIdeal, waitingCap)
            VStack(spacing: Chrome.groupGap) {
                if !rows.waiting.isEmpty {
                    group(rows.waiting, column: .waiting)
                        .frame(height: waitingHeight)
                }
                if !rows.advancing.isEmpty {
                    group(rows.advancing, column: .advancing)
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
        Chrome.groupHeader + items.map(rowHeight).reduce(0, +) + CGFloat(max(0, items.count - 1)) * cellGap + Chrome.fade
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column) -> some View {
        VStack(spacing: 0) {
            SectionHeader(Dotted(column.title), level: .group, count: items.count, countInk: column.countInk(palette))
                .railGroupHeader()
                .padding(.horizontal, RowMetrics.bleed)
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
                    .safeAreaPadding(.bottom, Chrome.fade)
                }
                .scrollIndicators(.hidden)
                .fades(.bottom)
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

extension View {
    func railGroupHeader() -> some View {
        padding(.bottom, Spacing.tight).frame(maxWidth: .infinity, alignment: .bottomLeading).frame(height: Chrome.groupHeader, alignment: .bottom)
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
