import SwiftUI

private nonisolated let outlineSpace = "TaskOutline"

/// 比较只看行与两个落点：动作只由这三样与工作区定，相等时读它的行留着的旧闭包做的是同一件事。
struct TaskStructure: Equatable {
    let row: UUID
    let indentMove: TaskMove?
    let outdentMove: TaskMove?
    let commit: (TaskMove) -> Void

    var indent: (() -> Void)? { indentMove.map { move in { commit(move) } } }
    var outdent: (() -> Void)? { outdentMove.map { move in { commit(move) } } }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.indentMove == b.indentMove && a.outdentMove == b.outdentMove }

    /// 读屏动作里的结构操作：手机上缩进已在右滑里（轻扫的读屏动作），反缩进只有拖放。
    #if os(macOS)
    static let spoken: [CardMenu.Item] = [.indent, .outdent]
    #else
    static let spoken: [CardMenu.Item] = [.outdent]
    #endif
}

extension EnvironmentValues {
    @Entry var taskStructure: TaskStructure?
}

/// 落点规则全在 `TaskTree`，这里只管手势。
/// 行之间不让位（同提醒事项的插入线）：拖动期间不重排，也就不会每帧重算布局。
struct TaskOutline<Line: View>: View {
    /// 拖放落点按整个项目页的层级算，所以能从别的大纲拖进来。
    private let whole: TaskTree
    private let tree: TaskTree
    private let line: (TaskTree.Row) -> Line
    /// 行数多到一屏放不下、外面又是固定高度的滚动区时，从第几行起改用懒加载栈，否则整列的行都要在打开的那一圈里量一遍；nil 是全部直接建。
    /// 前面的行总在普通栈里：懒加载栈对没建的行只报估算高度（`TaskFoldAnchor`），项目页折起时列出的行放这里，收起后大纲高度当场是准的，展开收起也不重建它们。
    private let lazyAfter: Int?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardDrags) private var drags
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = OutlineDrag()
    @State private var commits = 0

    init(tree: TaskTree, roots: [UUID]? = nil, lazyAfter: Int? = nil, @ViewBuilder line: @escaping (TaskTree.Row) -> Line) {
        self.lazyAfter = lazyAfter
        whole = tree
        self.tree = roots.map(tree.scoped(to:)) ?? tree
        self.line = line
    }

    /// 子任务的圈（小一号）左缘对着上级标题的起点，层级靠对齐读出来。
    static var indentWidth: CGFloat {
        TaskMetrics.ringColumn + TaskMetrics.columnGap - (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    }

    // body 不读落点与拖着的是哪条（拖动时每移一下都变）：只有落点的几个小视图读，拖动期间列表本身不重算
    var body: some View {
        let rows = tree.rows()
        Group {
            if let lazyAfter {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.prefix(lazyAfter)) { item($0) }
                    // 没有后面的行时不留空的懒加载栈：它会先报一次上回估算的高度
                    if rows.count > lazyAfter {
                        LazyVStack(alignment: .leading, spacing: 0) { ForEach(rows.dropFirst(lazyAfter)) { item($0) } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) { ForEach(rows) { item($0) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(outlineSpace))
        .background(alignment: .topLeading) { OutlineTargets(drag: drag, rows: rows, indent: Self.indentWidth, layer: .fill) }
        .overlay(alignment: .topLeading) {
            OutlineTargets(drag: drag, rows: rows, indent: Self.indentWidth, layer: .mark)
            InsertionLine(drag: drag, first: rows.first?.id, indent: Self.indentWidth)
        }
        .cardDrop(hover: { hover($0, rows: rows) }, perform: { perform($0, at: $1, rows: rows) })
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: rows.map(\.id))
        .sensoryFeedback(.impact(weight: .medium), trigger: commits)
    }

    private func item(_ row: TaskTree.Row) -> some View {
        let structure = TaskStructure(row: row.id, indentMove: tree.indent(row.id), outdentMove: tree.outdent(row.id)) { commit(row.id, $0) }
        return line(row)
        .padding(.leading, CGFloat(row.depth) * Self.indentWidth)
        .contentShape(.rect)
        .environment(\.taskStructure, structure)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(outlineSpace)) } action: { drag.frames[row.id] = $0 }
        .cardDraggable(.task(row.id), shape: .rect(cornerRadius: Radius.row))
        #if os(iOS)
        .rowSwipes(.card(row.task, workspace: workspace, structure: structure))
        #endif
    }

    private func hover(_ point: CGPoint?, rows: [TaskTree.Row]) {
        guard let point, let dragged = drags?.current else { return drag.end() }
        switch dragged {
        case .idea: drag.setIdea(row(at: point, in: rows))
        case .task(let id): drag.set(target(id, at: point, rows: rows))
        case .session: drag.end()
        }
    }

    /// 接进正文的那一下不另震：提示条出来时有一下（`NoticeBanner`）。
    private func perform(_ dragged: DraggedCard, at point: CGPoint, rows: [TaskTree.Row]) {
        switch dragged {
        case .idea(let idea):
            guard let target = row(at: point, in: rows) else { return }
            workspace.attempt { try await workspace.mergeIdea(idea, into: target) }
        case .task(let task):
            guard let move = target(task, at: point, rows: rows)?.move else { return }
            commit(task, move)
        case .session: break
        }
    }

    private func row(at point: CGPoint, in rows: [TaskTree.Row]) -> UUID? {
        rows.first { drag.frames[$0.id]?.contains(point) == true }?.id
    }

    private func target(_ task: UUID, at point: CGPoint, rows: [TaskTree.Row]) -> TaskDrop? {
        guard whole.task(task) != nil else { return nil }
        let start = drag.startX ?? point.x
        drag.startX = start
        let shift = Int(((point.x - start) / Self.indentWidth).rounded())
        return whole.drop(task, rows: rows, frames: drag.frames, at: point, depthShift: shift)
    }

    private func commit(_ id: UUID, _ move: TaskMove) {
        commits += 1
        workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
    }
}

/// 起点与行的位置不参与排版，不观察；落点只在变了时才写。
@Observable
final class OutlineDrag {
    private(set) var drop: TaskDrop?
    private(set) var idea: UUID?
    @ObservationIgnored var startX: CGFloat?
    @ObservationIgnored var frames: [UUID: CGRect] = [:]

    func set(_ next: TaskDrop?) {
        if drop != next { drop = next }
    }

    func setIdea(_ next: UUID?) {
        if idea != next { idea = next }
    }

    func end() {
        startX = nil
        set(nil)
        setIdea(nil)
    }

    var target: UUID? {
        if let idea { return idea }
        if case .onto(let id) = drop?.mark { return id }
        return nil
    }
}
