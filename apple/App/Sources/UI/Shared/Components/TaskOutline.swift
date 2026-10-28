import SwiftUI

/// 大纲自己的坐标系：行的位置与拖放的落点都在这里量。
private nonisolated let outlineSpace = "TaskOutline"

/// 一行任务在大纲里能做的结构操作（做不了的为 nil）。手机上缩进进轻扫与同源的读屏动作（`RowSwipes.card`），任务行从环境里取来放进读屏动作（`spoken`）；做什么只在 `CardMenu.Item.run`。
struct TaskStructure {
    var indent: (() -> Void)?
    var outdent: (() -> Void)?

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

/// 任务大纲（手机与 Mac 的项目页共用）：按 `TaskTree` 缩进排出全部行（只有两级，不折起）。
/// 手势用系统拖放（手机长按抬起，行上不挂长按菜单，见 `TaskLine`；Mac 按住拖）：停在一行中部高亮、松手成为它的子任务；停在两行之间出插入线，
/// 横向挪动改层级（插入线的起点跟着缩进）。拖来的是灵感（墙上的卡）时没有行间：一拖起来每一行都铺一层淡底（都接得住），指针下的那一行亮起，
/// 松手灵感接到它的正文后面（`Workspace.mergeIdea`）；纸底的"添加任务"同时换成新建的落点（`newTaskDrop`）。
/// 手机上轻扫按 `CardMenu.swipes`：右滑缩进，左滑删除与"更多"（`rowSwipes`）。落点规则全在 `TaskTree`，这里只管手势；画在 `TaskDropMarks.swift`。
/// 行之间不让位（同提醒事项的插入线）：拖动期间不重排，也就不会每帧重算布局。
struct TaskOutline<Line: View>: View {
    /// 整个项目页的层级：拖放落点按它算，所以能从别的大纲拖进来。
    private let whole: TaskTree
    /// 这个大纲显示的范围：行、缩进与反缩进按它算。
    private let tree: TaskTree
    private let line: (TaskTree.Row) -> Line
    /// 从第几行起按需建（只建看得见的），nil 是都直接建：外面给了固定高度的滚动区、行数多到一屏放不下时用，否则整列的行都要在打开的那一圈里量一遍。
    /// 前面那几行总在普通栈里：项目页折起时列出的行放这里，收起后大纲的高度当场是准的（懒加载栈对没建的行只报估算的高度，`TaskFoldAnchor`），
    /// 展开、收起也不重建它们。
    private let lazyAfter: Int?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardDrags) private var drags
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = OutlineDrag()
    @State private var commits = 0

    /// `roots`：只显示这些顶层任务及其子树（项目页的前几条），结构操作也只在里面算；nil 是全部。
    init(tree: TaskTree, roots: [UUID]? = nil, lazyAfter: Int? = nil, @ViewBuilder line: @escaping (TaskTree.Row) -> Line) {
        self.lazyAfter = lazyAfter
        whole = tree
        self.tree = roots.map(tree.scoped(to:)) ?? tree
        self.line = line
    }

    /// 一级缩进：子任务的圈（小一号）左缘对着上级标题的起点（`TaskLine`），层级靠对齐读出来。
    static var indentWidth: CGFloat {
        TaskMetrics.ringColumn + TaskMetrics.columnGap - (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    }

    // 视图体不读落点（拖动时每移一下都变）与拖着的是哪条：只有落点的几个小视图读它们，拖动期间列表本身不重算
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
        let structure = TaskStructure(
            indent: tree.indent(row.id).map { move in { commit(row.id, move) } },
            outdent: tree.outdent(row.id).map { move in { commit(row.id, move) } })
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

    /// 指针在大纲里移动：拖着灵感只认指针下的那一行，拖着任务按 `TaskTree.drop` 算行上还是行间。别的页拖来的（这一页没记着）不画。
    private func hover(_ point: CGPoint?, rows: [TaskTree.Row]) {
        guard let point, let dragged = drags?.current else { return drag.end() }
        switch dragged {
        case .idea: drag.setIdea(row(at: point, in: rows))
        case .task(let id): drag.set(target(id, at: point, rows: rows))
        }
    }

    /// 只落拖进来的那一条，落点按松手的位置重算。接进正文的那一下不另震：提示条出来时有一下（`NoticeBanner`）。
    private func perform(_ dragged: DraggedCard, at point: CGPoint, rows: [TaskTree.Row]) {
        switch dragged {
        case .idea(let idea):
            guard let target = row(at: point, in: rows) else { return }
            workspace.attempt { try await workspace.mergeIdea(idea, into: target) }
        case .task(let task):
            guard let move = target(task, at: point, rows: rows)?.move else { return }
            commit(task, move)
        }
    }

    private func row(at point: CGPoint, in rows: [TaskTree.Row]) -> UUID? {
        rows.first { drag.frames[$0.id]?.contains(point) == true }?.id
    }

    /// 横移从拖进这个大纲时的横坐标量起，一级缩进算一档。拖来的任务不在这一页时没有落点。
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

/// 一个大纲里的落点状态。起点与行的位置不参与排版（不观察）；落点只由落点的几个小视图读，且只在变了时才写。
@Observable
final class OutlineDrag {
    private(set) var drop: TaskDrop?
    /// 拖着灵感时指针下的那一行：松手接进它的正文。
    private(set) var idea: UUID?
    /// 拖进这个大纲时的横坐标：横移从这里量。
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

    /// 亮起的那一行：拖着灵感时指针下的，拖着任务时要成为它子任务的。
    var target: UUID? {
        if let idea { return idea }
        if case .onto(let id) = drop?.mark { return id }
        return nil
    }
}
