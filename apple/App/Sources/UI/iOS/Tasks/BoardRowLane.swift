#if os(iOS)
import SwiftUI

/// 行头是一块贴屏边的写字玻璃，卡滑动时从它下面过，不遮罩、不在它右沿裁掉（docs/layout.md「栏头与页顶」）。
/// 玻璃贴屏边、不留缝：留缝时停着的上一张卡的尾巴在缝里露出碎字。
/// 辅助字号下一行只叠一排、一张卡几乎占满可见宽：窄卡里大字一行只放得下两个字。
/// 滚动区不裁内容：卡换行时飞过行的上下沿，横向超出的在屏幕外。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）。
struct BoardRowLane<Above: View, Content: View>: View {
    let column: TaskBoard.Column
    let count: Int
    let targeted: Bool
    let rewind: UUID?
    @ViewBuilder let above: Above
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var advancingHeight = BoardRowMetrics.advancingHeight
    @ScaledMetric(relativeTo: .subheadline) private var waitingHeight = BoardRowMetrics.waitingHeight
    @ScaledMetric(relativeTo: .caption2) private var lightHeight = BoardRowMetrics.lightHeight
    @ScaledMetric(relativeTo: .caption) private var spineHeight = BoardRowMetrics.spineHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .subheadline) private var addHeight = BoardRowMetrics.addHeight

    private var add: LaneAdd? { LaneAdd.of(column, in: workspace) }
    private var adds: Bool { add != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.lead).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .frame(minHeight: column.light ? lightHeight + (adds ? addHeight : 0) : spineHeight + 2 * BoardRowMetrics.spineInset, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            BoardRowSpine(column: column, count: count, add: add)
                .frame(width: BoardRowMetrics.spine)
                .frame(minHeight: column.light ? lightHeight : spineHeight, maxHeight: column.light ? nil : .infinity)
                .fixedSize(horizontal: false, vertical: column.light)
                .glass(in: UnevenRoundedRectangle(bottomTrailingRadius: BoardRowMetrics.spine / 2, topTrailingRadius: BoardRowMetrics.spine / 2, style: .continuous))
                .padding(.vertical, column.light ? 0 : BoardRowMetrics.spineInset)
        }
        .padding(.vertical, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted) }
    }

    private var strip: some View {
        let cell = cellHeight
        let tier = count == 0 || column.light ? GridItem(.flexible(), spacing: BoardRowMetrics.gap) : GridItem(.adaptive(minimum: cell), spacing: BoardRowMetrics.gap)
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: [tier], spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡：卡、空格与"更早做完的"铺满格
                    Group { content }
                        .containerRelativeFrame(.horizontal) { [share = cardShare] width, _ in (width * share).rounded() }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollTargetLayout()
            }
            .safeAreaPadding(.leading, BoardRowMetrics.lead)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .boardLane(column)
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: cell, idealHeight: cell * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1), maxHeight: .infinity)
            .environment(\.boardRow, true)
            .environment(\.boardTitle, BoardCardMetrics.title(column, cardWidth: nil, typeSize: typeSize))
            .onChange(of: rewind, initial: true) {
                if let rewind { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    private var tiers: Int { typeSize.isAccessibilitySize ? 1 : column.rowTiers }

    private var cardShare: CGFloat { typeSize.isAccessibilitySize ? BoardRowMetrics.wideCardWidth : BoardRowMetrics.cardWidth }

    private var cellHeight: CGFloat {
        switch column {
        case .advancing: advancingHeight
        case .waiting: waitingHeight
        case .todo, .done: lightHeight
        }
    }
}

enum BoardRowMetrics {
    static let advancingHeight: CGFloat = 76
    static let waitingHeight: CGFloat = 60
    /// 行头与它同高，上下各留六七点：再矮行头就贴着玻璃上下沿，再高推进中、等你在 iPhone 17 上排不下三排（`PhoneBoard`）。
    static let lightHeight: CGFloat = 64
    static let cardWidth: CGFloat = 0.62
    static let wideCardWidth: CGFloat = 0.88
    static let spine: CGFloat = 32
    static let spineHeight: CGFloat = 92
    static let spineInset: CGFloat = 10
    static let addHeight: CGFloat = 30
    static let lead: CGFloat = spine + gap
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 4
}

private struct BoardRowSpine: View {
    let column: TaskBoard.Column
    let count: Int
    let add: LaneAdd?
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption) private var mark: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var lightMark: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            marks
            if let add {
                LaneAddButton(add).font(Typography.secondary.weight(.semibold)).frame(maxWidth: .infinity, minHeight: BoardRowMetrics.addHeight)
            }
        }
    }

    private var marks: some View {
        Group {
            if column.light {
                VStack(spacing: Spacing.hair) {
                    HStack(spacing: Spacing.hair) {
                        BoardLaneMark(column: column, size: lightMark)
                        number.font(Typography.caption2.weight(.semibold))
                    }
                    title.font(Typography.caption2.weight(.semibold))
                }
            } else {
                VStack(spacing: Spacing.hair) {
                    BoardLaneMark(column: column, size: mark)
                    title.font(Typography.caption.weight(.semibold))
                    number.font(Typography.bodyStrong)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityAddTraits(.isHeader)
    }

    private var title: some View {
        ZStack {
            ForEach(TaskBoard.Column.allCases) { Self.name($0.title).hidden() }
            Self.name(column.title)
        }
        .foregroundStyle(column.light ? palette.ink3 : palette.ink2)
    }

    private var number: some View {
        Text("\(count)").monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).minimumScaleFactor(0.7).lineLimit(1)
    }

    /// 竖排的汉字按字的行高排，一字一行太散：收这么多读成一个词（光学校准，随字号的行高走不了档）。
    private static let charTuck: CGFloat = 2

    /// 汉字一字一行竖排；拉丁字母竖排读不成词，整词侧转 90°。
    @ViewBuilder private static func name(_ title: String) -> some View {
        if title.unicodeScalars.allSatisfy(\.properties.isIdeographic) {
            VStack(spacing: -Self.charTuck) {
                ForEach(Array(title.enumerated()), id: \.offset) { Text(String($1)) }
            }
        } else {
            Sideways { Text(title).lineLimit(1).fixedSize().rotationEffect(.degrees(-90)) }
        }
    }
}

/// 侧转 90° 的一个子视图占转过之后的框（`rotationEffect` 只转画面，不换排版的宽高）。
private struct Sideways: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}
#endif
