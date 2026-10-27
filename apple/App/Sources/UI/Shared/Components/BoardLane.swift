import SwiftUI

/// 看板一列（手机一行）身后那一块（`BoardColumn`、`BoardRowLane`）：平时什么都没有——列（行）靠留白与列头分开，身后不按列铺色，
/// 列的颜色只在记号（`BoardLaneMark`）与卡的纸上（`TaskBoard.Column.paper`）；拖着卡停在上面时铺一层选中底，圆角是卡片圆角加卡离列边的空（同心）。
/// 只铺实色：侧栏开合时整面墙每帧重画，大面积不铺渐变、不描边。
struct BoardLane: View {
    let targeted: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if targeted { RoundedRectangle(cornerRadius: Radius.sheet).fill(palette.selection).transition(.opacity) }
        }
        .animation(Motion.fade, value: targeted)
    }
}

/// 列头：状态色实心圆里一个白字形（`BoardLaneMark`）、列名，右边是这一列的数。数随列的轻重（`BoardWeight.swift`）：推进中、等你放大、着状态色，
/// 待办、已完成与列名同字号、列名与数都是 ink3。卡片开头的记号是空心描边，与它分得开。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        // 窄到放不下时先不写列名、再不画记号，数一直在（Mac 待办的列头给左上的分段让位、侧栏收起时）
        ViewThatFits(in: .horizontal) {
            row(title: true, mark: true)
            row(title: false, mark: true)
            row(title: false, mark: false)
        }
        .lineLimit(1)
        .frame(height: Self.height)
        // 读屏总念列名与数，不随看得见的那一档少念
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(title: Bool, mark: Bool) -> some View {
        HStack(spacing: 8) {
            if mark { BoardLaneMark(column: column, size: Self.mark) }
            if title { Text(column.title).font(Self.font).foregroundStyle(column.light ? palette.ink3 : palette.ink2).fixedSize() }
            Spacer(minLength: 8)
            Text("\(count)").font(column.light ? Self.font : Self.countFont).monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).fixedSize()
        }
    }

    #if os(macOS)
    private static let font = Typography.secondary.weight(.semibold)
    private static let countFont = Typography.heading
    private static let mark: CGFloat = 16
    /// 排在窗口最顶那一排里，与工具栏的玻璃同高（`boardTopRow`）
    static let height = Spacing.toolbarControl
    #else
    private static let font = Font.headline
    private static let countFont = Font.title2.weight(.semibold)
    private static let mark: CGFloat = 20
    static let height: CGFloat = 52
    #endif
}

/// 一列的记号（Mac 与 iPad 的列头、手机的行头、任务气泡顶上的列名）：状态色实心圆 + 白色字形——待办暖灰三横线、推进中靛青波形、等你赭黄问号、已完成石绿对勾。
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
