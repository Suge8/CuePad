import SwiftUI

/// 只铺实色：侧栏开合时整面墙每帧重画，大面积不铺渐变、不描边。
/// 否决过：四列各垫一块常驻的淡底托盘——暖灰桌面上再叠一层灰，整页发闷。
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
    var icon = Icon.add
    let action: () -> Void

    static func of(_ column: TaskBoard.Column, in workspace: Workspace) -> LaneAdd? {
        switch column {
        case .todo: LaneAdd(title: "添加任务") { workspace.addsTask = true }
        case .advancing: LaneAdd(title: "新会话") { workspace.openNewSession(in: workspace.scopedProject) }
        case .waiting, .done: nil
        }
    }

    /// 归档做完的：范围跟着看板（`Workspace.archiveCompletedTasks`），说法也跟着写是哪个项目的。
    static func archive(in workspace: Workspace) -> LaneAdd {
        let scope = workspace.catalog?.project(workspace.scopedProject)?.shownName
        return LaneAdd(title: scope.map { "归档「\($0)」做完的（置顶的留着）" } ?? "全部归档做完的（置顶的留着）", icon: .archive) {
            workspace.attempt { try await workspace.archiveCompletedTasks() }
        }
    }
}

/// 列头里是一颗垫着淡底的圆钮（`cell` 的宽就是它的直径）：光一个"+"字在列头里认不出是钮。
/// Mac 上钮就是这颗圆，悬停的底也只是它——钮比圆宽时悬停的底盖到旁边的数上、高出列头。
/// 手机上命中与排版分开：圆照样只占 `cell` 那么宽的排版，钮本身至少 `ControlSize.target` 宽，居中浮在格上、不占排版——
/// 按命中宽排会把列名挤短（手机横屏四列的待办列头里，英文"To Do"就截成"To…"）。
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
            #if os(macOS)
            button(disc: cell.width).frame(height: cell.height)
            #else
            Color.clear.frame(width: cell.width, height: cell.height)
                .overlay { button(disc: cell.width).frame(width: max(cell.width, ControlSize.target), height: cell.height) }
            #endif
        } else {
            button(disc: nil)
        }
    }

    private func button(disc: CGFloat?) -> some View {
        Button(action: add.action) {
            if let disc {
                Label(add.title, icon: add.icon).labelStyle(.iconOnly)
                    .frame(width: disc, height: disc)
                    .background(palette.fill, in: .circle)
                    #if os(iOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                    .contentShape(.rect)
            } else {
                Label(add.title, icon: add.icon).labelStyle(.iconOnly).contentShape(.rect)
            }
        }
        // 加号是这一列的主动作；别的（已完成的全部归档）是收拾，淡一档
        .foregroundStyle(add.icon != .add ? palette.ink3 : disc == nil ? palette.signature : palette.ink)
        .buttonStyle(PressStyle(disc == nil ? .inline : .button))
        .help(Text(add.title))
    }
}

extension Workspace {
    func openNewSession(in project: UUID? = nil) {
        newSession = SessionStart(project: project ?? currentProject)
    }
}

/// 不用按宽挑候选（`ViewThatFits`）：多一颗"+"的列，挑候选时整个列名先没了（1280 宽的 Mac 上只剩「11 ＋」），四列看着不是一套规则。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    /// 已完成那一列有做完的任务：列尾那一格（别的列放加号的地方）是全部归档，不随"更早做完的"展没展开。手机按行排时列头没有这一格，入口在"更早做完的"那一页。
    var archives = false
    @Environment(\.palette) private var palette
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let add = archives ? .archive(in: workspace) : LaneAdd.of(column, in: workspace)
        let button = add == nil ? 0 : Self.add
        // 列名在列的正中，两边各让出钮那么宽；窄到放不下时只让右边，列名靠左挪半个钮、不截字。
        // 两个候选都是整个列名，不会像按宽挑"有名没名"那样先把列名挑没（见上）
        return ViewThatFits(in: .horizontal) {
            row.padding(.horizontal, button)
            row.padding(.trailing, button)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(.isHeader)
        .overlay(alignment: .trailing) {
            if let add { LaneAddButton(add, cell: CGSize(width: Self.add, height: Self.height)).font(Self.font) }
        }
        .frame(height: Self.height)
    }

    private var row: some View {
        HStack(spacing: 0) {
            BoardLaneMark(column: column, size: Self.mark)
            Text(column.title).foregroundStyle(column.light ? palette.ink3 : palette.ink2).truncationMode(.tail)
                .padding(.leading, Spacing.glyph)
            // 数紧跟列名：四列同一种排法
            Text("\(count)").monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).fixedSize()
                .padding(.leading, Spacing.glyph)
        }
        .font(Self.font)
    }

    private static let font = Typography.laneTitle
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
