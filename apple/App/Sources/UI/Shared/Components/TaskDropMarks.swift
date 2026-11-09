import SwiftUI

/// 画在大纲这一层、按行的位置摆（`rowPlate`），不画在行里：手机的行挂着轻扫，轻扫把行裁在自己的框里，伸出行框的底会被切成直角。两层：底垫在行后面（`fill`），描边与小签盖在行上（`mark`）。
/// 拖着灵感时每一行铺一层淡底，一拖起来就看得出哪些接得住；亮起的是同一块，换行时滑过去，不是这行灭、那行亮。
struct OutlineTargets: View {
    enum Layer { case fill, mark }

    let drag: OutlineDrag
    let rows: [TaskTree.Row]
    let indent: CGFloat
    let layer: Layer
    @Environment(\.cardDrags) private var drags
    @Environment(\.palette) private var palette
    @Environment(\.rowSurface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 2

    var body: some View {
        let dragged = drags?.current
        let idea = dragged?.idea != nil
        // 拖完（放下或取消）就不画：大纲自己可能收不到"拖走了"
        let target = dragged == nil ? nil : drag.target
        ZStack(alignment: .topLeading) {
            switch layer {
            case .fill:
                if idea {
                    ForEach(rows) { row in
                        if let rect = rect(row) { place(in: rect) { $0.fill(palette.fill) }.transition(.opacity) }
                    }
                }
                if let rect = target.flatMap(rect) { place(in: rect) { $0.fill(palette.selection) }.transition(.opacity) }
            case .mark:
                if idea, let rect = target.flatMap(rect) {
                    place(in: rect) { $0.stroke(palette.signature, lineWidth: 1.5) }
                        .overlay(alignment: .trailing) { badge }
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.fade, value: idea)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: target)
    }

    // 实底的小签盖在行尾的旁注（时间、"开始"）上，字不叠字；底色同亮起的行
    private var badge: some View {
        Label("接到正文后面", icon: .add).labelStyle(.titleAndIcon)
            .font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.signature)
            .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
            .background(palette.selection, in: .capsule)
            .background(surface ?? palette.paper, in: .capsule)
    }

    private func place(in rect: CGRect, @ViewBuilder _ plate: @escaping (ConcentricRectangle) -> some View) -> some View {
        Color.clear.frame(width: rect.width, height: rect.height).rowPlate(plate).offset(x: rect.minX, y: rect.minY)
    }

    private func rect(_ id: UUID) -> CGRect? { rows.first { $0.id == id }.flatMap(rect) }

    private func rect(_ row: TaskTree.Row) -> CGRect? {
        guard let frame = drag.frames[row.id] else { return nil }
        let inset = CGFloat(row.depth) * indent
        return CGRect(x: frame.minX + inset, y: frame.minY + Self.gap, width: frame.width - inset, height: frame.height - Self.gap * 2)
    }
}

/// 落点变化时（含拖着灵感换了一行）一下轻触感。
struct InsertionLine: View {
    let drag: OutlineDrag
    let first: UUID?
    let indent: CGFloat
    @Environment(\.cardDrags) private var drags

    var body: some View {
        ZStack(alignment: .topLeading) {
            if drags?.current != nil, case .gap(let after, let depth) = drag.drop?.mark, let top = first.flatMap({ drag.frames[$0] }) {
                let y = after.flatMap { drag.frames[$0]?.maxY } ?? top.minY
                let x = CGFloat(depth) * indent
                InsertionMark().frame(width: max(top.maxX - x, 0)).offset(x: x, y: y - InsertionMark.ring / 2)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.fade, value: drag.drop?.mark)
        .sensoryFeedback(.selection, trigger: drag.drop?.mark) { _, mark in mark != nil }
        .sensoryFeedback(.selection, trigger: drag.idea) { _, row in row != nil }
    }
}

struct InsertionMark: View {
    static let ring: CGFloat = 9
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(palette.ink, lineWidth: 2).frame(width: Self.ring, height: Self.ring)
            Capsule().fill(palette.ink).frame(height: 2)
        }
    }
}

extension View {
    /// 挂在整行上（连同右边的开合）：落点大，拖着时开合也用不上。
    func newTaskDrop() -> some View { modifier(NewTaskDrop()) }
}

private struct NewTaskDrop: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardDrags) private var drags
    @State private var over = false

    func body(content: Content) -> some View {
        let shown = drags?.current?.idea != nil
        content
            .overlay { if shown { NewTaskSlot(over: over).transition(.opacity) } }
            .cardDrop(isEnabled: shown, hover: { over = $0 != nil }) { dragged, _ in
                guard let idea = dragged.idea else { return }
                workspace.attempt { try await workspace.newTask(fromIdea: idea) }
            }
            .animation(Motion.fade, value: shown)
            .sensoryFeedback(.selection, trigger: over) { _, now in now }
    }
}

/// 垫纸色，盖住下面的"添加任务"与开合。
private struct NewTaskSlot: View {
    let over: Bool
    @Environment(\.palette) private var palette
    @Environment(\.rowSurface) private var surface

    var body: some View {
        HStack(spacing: TaskMetrics.columnGap) {
            Image(.add).font(TaskMetrics.caption.weight(.semibold)).frame(width: TaskMetrics.ringColumn).readerHidden(true)
            Text("新建任务").font(Typography.body.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.signature)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rowPlate { shape in
            shape.fill(surface ?? palette.paper)
                .overlay { if over { shape.fill(palette.selection) } }
                .overlay { shape.stroke(over ? palette.signature : palette.signatureSoft, style: StrokeStyle(lineWidth: 1.5, dash: over ? [] : [5, 4])) }
        }
        .padding(.vertical, Spacing.hair)
        .animation(Motion.fade, value: over)
        .allowsHitTesting(false)
    }
}
