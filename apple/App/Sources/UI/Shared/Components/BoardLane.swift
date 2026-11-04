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

extension EnvironmentValues {
    /// 看板待办那一列（行）头上的"+"：点它开添加任务（进展页给：手机与 iPad `ProgressScreen`，Mac `TaskBoardPage`）；nil 不画。
    @Entry var laneAddsTask: (() -> Void)? = nil
    /// 推进中那一列（行）头上的"+"：点它开新会话（`Workspace.openNewSession`）。三端的新会话都只在这里，另外只有会话列表空着时那一颗（`SessionList`）；nil 不画。
    @Entry var laneAddsSession: (() -> Void)? = nil
}

/// 列头、行头上的"+"（三端同这一处）：待办是添加任务（`laneAddsTask`），推进中是新会话（`laneAddsSession`），页没给就没有。
/// 读它的是四列看板的列头（`BoardColumnHeader`）与手机竖版看板的行头（`BoardRowLane`），各自只给它多大。
struct LaneAdd {
    let title: LocalizedStringResource
    let action: () -> Void

    static func of(_ column: TaskBoard.Column, task: (() -> Void)?, session: (() -> Void)?) -> LaneAdd? {
        switch column {
        case .todo: task.map { LaneAdd(title: "添加任务", action: $0) }
        case .advancing: session.map { LaneAdd(title: "新会话", action: $0) }
        case .waiting, .done: nil
        }
    }
}

/// "+"那一颗：只画图标、着品牌靛青，按下与悬停是行内的淡底（`PressStyle(.inline)`）；字号与按得到的那一格由放它的那一处给。
struct LaneAddButton: View {
    let add: LaneAdd
    @Environment(\.palette) private var palette

    init(_ add: LaneAdd) { self.add = add }

    var body: some View {
        Button(add.title, icon: .add, action: add.action)
            .labelStyle(.iconOnly)
            .foregroundStyle(palette.signature)
            .contentShape(.rect)
            .buttonStyle(PressStyle(.inline))
    }
}

extension Workspace {
    /// 推进中列头的"+"：新会话开在 `project`（看板的项目范围，没选时 nil、开在当前项目）。Mac 是窗口里的表单（`NewSessionPanel`），手机与 iPad 是新会话的输入框。
    func openNewSession(in project: UUID?) {
        #if os(macOS)
        newSession(in: project)
        #else
        newSession = .init(project: project)
        #endif
    }
}

/// 列头：状态色实心圆里一个白字形（`BoardLaneMark`）、列名，右边是这一列的数。数随列的轻重（`BoardWeight.swift`）：推进中、等你放大、着状态色，
/// 待办、已完成与列名同字号、列名与数都是 ink3。卡片开头的记号是空心描边，与它分得开。
/// 待办与推进中的列头在数右边可带一颗"+"（`LaneAdd`：添加任务、新会话，同手机竖版看板行头的那一颗）。
/// 四列同一套排法：放不下时先收紧列名与数之间的空，再把列名截成省略号，记号、数与"+"一直在。
/// 不用按宽挑候选（`ViewThatFits`）：多一颗"+"的列，挑候选时整个列名先没了（1280 宽的 Mac 上只剩「11 ＋」），四列看着不是一套规则。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette
    @Environment(\.laneAddsTask) private var addTask
    @Environment(\.laneAddsSession) private var addSession

    var body: some View {
        HStack(spacing: 0) {
            row
                .lineLimit(1)
                // 读屏总念列名与数，列名截没了也照念
                .accessibilityElement(children: .ignore)
            .accessibilityLabel(column.title)
            .accessibilityValue("\(count)")
            .accessibilityAddTraits(.isHeader)
            if let add = LaneAdd.of(column, task: addTask, session: addSession) {
                LaneAddButton(add).font(Self.font).frame(width: Self.add, height: Self.height)
            }
        }
        .frame(height: Self.height)
    }

    private var row: some View {
        // 记号与列名隔一道，列名与数之间只靠弹性的空：放不下时先把这道空收到最小，再截列名
        HStack(spacing: 0) {
            BoardLaneMark(column: column, size: Self.mark)
            Text(column.title).font(Self.font).foregroundStyle(column.light ? palette.ink3 : palette.ink2).truncationMode(.tail)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            Text("\(count)").font(column.light ? Self.font : Self.countFont).monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).fixedSize()
        }
    }

    private static let font = Typography.laneTitle
    private static let countFont = Typography.laneCount
    #if os(macOS)
    private static let mark: CGFloat = 16
    /// 与栏头那一排的玻璃同高（`boardTopRow`）
    static let height = ControlMetrics.height
    /// "+"占的宽：字形加一点按得到的余量（悬停底向外宽出，`PressStyle(.inline)`）；按列头高的方块会白占一截、把列名挤短。
    private static let add: CGFloat = 24
    #else
    private static let mark: CGFloat = 20
    static let height: CGFloat = 52
    /// 手指点得到的一格：高是列头的 52，宽收到 32（横屏四列的待办列头里，44 宽会把"待办"挤成省略号）。
    private static let add: CGFloat = 32
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
