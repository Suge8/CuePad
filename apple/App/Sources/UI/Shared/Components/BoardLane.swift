import SwiftUI

/// 看板一列的泳道（`BoardColumn` 铺在身后）：从列头起整列铺到窗口底，按列上色（色值是 `Palette` 的 `lane…`），上沿一线白高光，
/// 上两角圆角是卡片圆角加卡离泳道边的空（同心）。拖进来时再铺一层选中底。
struct BoardLane: View {
    let column: TaskBoard.Column
    let targeted: Bool
    @Environment(\.palette) private var palette

    static let radius = BoardCardMetrics.radius + BoardCardMetrics.inset

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Self.radius, topTrailingRadius: Self.radius, style: .continuous)
        // 高光是垫在下面的一层亮色、泳道往下让出一线：圆角处跟着弯，不用渐变描边（整列面积铺渐变，列一变宽整面重画）
        ZStack {
            shape.fill(palette.sheen)
            shape.fill(column.lane(palette)).padding(.top, 1)
            if targeted { shape.fill(palette.selection).transition(.opacity) }
        }
        .animation(HandOff.quick, value: targeted)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 列头：状态色实心圆里一个白字形（`BoardLaneMark`）、列名，右边是这一列的数（大字）。卡片开头的记号是空心描边，与它分得开。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            BoardLaneMark(column: column, size: Self.mark)
            Text(column.title).font(Self.font).foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
            Text("\(count)").font(Self.countFont).monospacedDigit().foregroundStyle(palette.ink).counting(count)
        }
        .lineLimit(1)
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private static let font = Typography.secondary.weight(.semibold)
    private static let countFont = Typography.heading
    private static let mark: CGFloat = 16
    static let height: CGFloat = 44
    #else
    private static let font = Font.headline
    private static let countFont = Font.title2.weight(.semibold)
    private static let mark: CGFloat = 20
    static let height: CGFloat = 52
    #endif
}

/// 一列的记号（列头、手机的分段胶囊）：状态色实心圆 + 白色字形——待办暖灰三横线、推进中靛青波形、等你赭黄问号、已完成石绿对勾。
struct BoardLaneMark: View {
    let column: TaskBoard.Column
    var size: CGFloat = 16
    @Environment(\.palette) private var palette

    var body: some View {
        LaneGlyph(column: column)
            .stroke(palette.onFill, style: StrokeStyle(lineWidth: size * 1.5 / LaneGlyph.grid, lineCap: .round, lineJoin: .round))
            .background(column.mark(palette), in: .circle)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 列头记号里的字形，画在 16 × 16 的格子里（设计稿原样）。
nonisolated private struct LaneGlyph: Shape {
    let column: TaskBoard.Column
    static let grid: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        switch column {
        case .todo:
            line([(4.8, 5.4), (11.2, 5.4)])
            line([(4.8, 8), (11.2, 8)])
            line([(4.8, 10.6), (8.8, 10.6)])
        case .advancing:
            line([(3.4, 8.4), (5.4, 8.4), (6.6, 5.6), (8.2, 10.6), (9.5, 7), (10.3, 8.4), (12.6, 8.4)])
        case .waiting:
            path.addArc(center: CGPoint(x: 8.05, y: 6.1), radius: 1.95, startAngle: .degrees(180), endAngle: .degrees(64), clockwise: false)
            path.addCurve(to: CGPoint(x: 8, y: 9.1), control1: CGPoint(x: 8.3, y: 8.15), control2: CGPoint(x: 8, y: 8.5))
            path.addLine(to: CGPoint(x: 8, y: 9.3))
            // 问号下的点：一截极短的圆头线
            line([(8, 11.4), (8, 11.41)])
        case .done:
            line([(5, 8.2), (7, 10.2), (11, 5.9)])
        }
        let scale = min(rect.width, rect.height) / Self.grid
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

extension TaskBoard.Column {
    /// 这一列泳道的底色。
    func lane(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.laneTodo
        case .advancing: palette.laneAdvancing
        case .waiting: palette.laneWaiting
        case .done: palette.laneDone
        }
    }

    /// 列头那颗实心圆的颜色：各列的状态色（待办没有状态色，是暖灰）。
    func mark(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.quietFill
        case .advancing: palette.signatureFill
        case .waiting: palette.waitingFill
        case .done: palette.repliedFill
        }
    }
}
