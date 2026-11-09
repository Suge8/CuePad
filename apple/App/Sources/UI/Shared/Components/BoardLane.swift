import SwiftUI

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

/// 三端的新会话都只在这里，另外只有会话列表空着时那一颗（`SessionList`）。动作直接调工作区，不经环境交下来：环境里的闭包没法比较，页每更新一次就让读它的列头全部重算。
struct LaneAdd {
    let title: LocalizedStringResource
    let action: () -> Void

    static func of(_ column: TaskBoard.Column, in workspace: Workspace) -> LaneAdd? {
        switch column {
        case .todo: LaneAdd(title: "添加任务") { workspace.addsTask = true }
        case .advancing: LaneAdd(title: "新会话") { workspace.openNewSession(in: workspace.scopedProject) }
        case .waiting, .done: nil
        }
    }
}

/// 命中与排版分开：格多宽就占多宽的排版，钮本身至少 `ControlSize.target` 宽（手机 44、Mac 28），
/// 居中浮在格上、两边压过旁边的数，不占排版——按命中宽排会把列名挤短（手机横屏四列的待办列头里，英文"To Do"就截成"To…"）。
/// 列头高本来就不低于 target，只横着扩。钮点得到的就是它自己的框：标签上外扩的 contentShape 出了按钮的框不认（实测），所以扩的是钮、不是形状。
struct LaneAddButton: View {
    let add: LaneAdd
    var cell: CGSize?
    @Environment(\.palette) private var palette

    init(_ add: LaneAdd, cell: CGSize? = nil) {
        self.add = add
        self.cell = cell
    }

    var body: some View {
        if let cell {
            Color.clear.frame(width: cell.width, height: cell.height)
                .overlay { button.frame(width: max(cell.width, ControlSize.target), height: cell.height) }
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: add.action) {
            Label(add.title, icon: .add)
                .labelStyle(.iconOnly)
                .frame(maxWidth: cell == nil ? nil : .infinity, maxHeight: cell == nil ? nil : .infinity)
                .contentShape(.rect)
        }
        .foregroundStyle(palette.signature)
        .buttonStyle(PressStyle(.inline))
    }
}

extension Workspace {
    func openNewSession(in project: UUID?) {
        #if os(macOS)
        newSession(in: project)
        #else
        newSession = .init(project: project)
        #endif
    }
}

/// 不用按宽挑候选（`ViewThatFits`）：多一颗"+"的列，挑候选时整个列名先没了（1280 宽的 Mac 上只剩「11 ＋」），四列看着不是一套规则。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            row
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
            .accessibilityLabel(column.title)
            .accessibilityValue("\(count)")
            .accessibilityAddTraits(.isHeader)
            if let add = LaneAdd.of(column, in: workspace) {
                LaneAddButton(add, cell: CGSize(width: Self.add, height: Self.height)).font(Self.font)
            }
        }
        .frame(height: Self.height)
    }

    private var row: some View {
        HStack(spacing: 0) {
            BoardLaneMark(column: column, size: Self.mark)
            Text(column.title).font(Self.font).foregroundStyle(column.light ? palette.ink3 : palette.ink2).truncationMode(.tail)
                .padding(.leading, Spacing.glyph)
            Spacer(minLength: Spacing.tight)
            Text("\(count)").font(column.light ? Self.font : Self.countFont).monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).fixedSize()
        }
    }

    private static let font = Typography.laneTitle
    private static let countFont = Typography.laneCount
    static var height: CGFloat { ControlSize.regular.height }
    #if os(macOS)
    private static let mark: CGFloat = 16
    static let add: CGFloat = 24
    #else
    private static let mark: CGFloat = 20
    static let add: CGFloat = 32
    #endif
}

struct BoardLaneMark: View {
    let column: TaskBoard.Column
    var size: CGFloat = 16
    @Environment(\.palette) private var palette

    var body: some View {
        LaneGlyph(column: column)
            .stroke(column.mark(palette), style: StrokeStyle(lineWidth: size * InkStateGeometry.heartbeatStrokeRatio, lineCap: .round, lineJoin: .round))
            .overlay {
                if column == .waiting {
                    let rect = CGRect(x: 0, y: 0, width: size, height: size)
                    let dot = InkStateGeometry.questionDot(in: rect)
                    Circle().fill(column.mark(palette)).frame(width: dot.width, height: dot.height)
                        .position(x: dot.midX, y: dot.midY)
                }
            }
            .frame(width: size, height: size)
    }
}

nonisolated private struct LaneGlyph: Shape {
    let column: TaskBoard.Column
    static let grid: CGFloat = 16
    func path(in rect: CGRect) -> Path {
        switch column {
        case .advancing: return Path(InkStateGeometry.heartbeat(in: rect))
        case .waiting: return Path(InkStateGeometry.question(in: rect))
        case .done: return Path(InkStateGeometry.check(in: rect))
        case .todo: break
        }
        var path = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        line([(3.2, 4.5), (12.8, 4.5)])
        line([(3.2, 8), (12.8, 8)])
        line([(3.2, 11.5), (9.6, 11.5)])
        let scale = min(rect.width, rect.height) / Self.grid
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

extension TaskBoard.Column {
    func mark(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.ink2
        case .advancing: palette.signature
        case .waiting: palette.waiting
        case .done: palette.replied
        }
    }
}
