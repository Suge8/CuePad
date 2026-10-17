import CueStore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// 大纲自己的坐标系：行的位置与拖放的落点都在这里量。
private nonisolated let outlineSpace = "TaskOutline"

/// 一行任务在大纲里能做的结构操作；做不了的为 nil。手机上它进轻扫与同源的读屏动作（`RowSwipes.card`），Mac 的任务行从环境里取来放进右键菜单与读屏动作。
struct TaskStructure {
    var indent: (() -> Void)?
    var outdent: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var taskStructure: TaskStructure?
}

/// 任务大纲（手机任务页与项目页、Mac 任务面板与项目页共用）：按 `TaskTree` 缩进排出全部行（只有两级，不折起）。
/// 手势用系统拖放（手机长按抬起，行上不挂长按菜单，见 `TaskLine`；Mac 按住拖）：停在一行中部高亮、松手成为它的步骤；停在两行之间出插入线，
/// 横向挪动改层级（插入线的起点跟着缩进）。手机上轻扫按 `CardMenu.swipes`：右滑缩进，左滑删除与反缩进（`rowSwipes`）。落点规则全在 `TaskTree`，这里只管手势与画。
/// 行之间不让位（同提醒事项的插入线）：拖动期间不重排，也就不会每帧重算布局。
struct TaskOutline<Line: View>: View {
    /// 整个看板（或项目页）的层级：拖放落点按它算，所以能从别的组拖进来。
    private let whole: TaskTree
    /// 这个大纲显示的范围：行、缩进与反缩进按它算。
    private let tree: TaskTree
    private let line: (TaskTree.Row) -> Line
    /// 从第几行起按需建（只建看得见的），nil 是都直接建：外面给了固定高度的滚动区、行数多到一屏放不下时用，否则整列的行都要在打开的那一圈里量一遍。
    /// 前面那几行总在普通栈里：项目页折起时列出的行放这里，收起后大纲的高度当场是准的（懒加载栈对没建的行只报估算的高度，`TaskFoldAnchor`），
    /// 展开、收起也不重建它们。
    private let lazyAfter: Int?
    /// 两行之间能不能落（改顺序、换项目）：行的先后是同级的手动顺序时能。看板的进行中按开始时间排，为 false（规则见 `TaskTree.drop`）。
    private let gaps: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = OutlineDrag()
    @State private var commits = 0

    /// `roots`：只显示这些顶层任务及其子树（看板的一组、项目页的前几条），结构操作也只在里面算；nil 是全部。
    init(tree: TaskTree, roots: [UUID]? = nil, gaps: Bool = true, lazyAfter: Int? = nil, @ViewBuilder line: @escaping (TaskTree.Row) -> Line) {
        self.lazyAfter = lazyAfter
        self.gaps = gaps
        whole = tree
        self.tree = roots.map(tree.scoped(to:)) ?? tree
        self.line = line
    }

    /// 一级缩进：步骤的圈（小一号）左缘对着上级标题的起点（`TaskLine`），层级靠对齐读出来。
    static var indentWidth: CGFloat {
        TaskMetrics.ringColumn + TaskMetrics.columnGap - (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    }

    // 视图体不读落点（拖动时每移一下都变）：只有高亮与插入线两个小视图读它，拖动期间列表本身不重算
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
        .overlay(alignment: .topLeading) { InsertionLine(drag: drag, first: rows.first?.id, indent: Self.indentWidth) }
        .onDrop(of: [.utf8PlainText], delegate: OutlineDrop(
            accepts: { TaskDragSession.shared.dragged.map { whole.task($0) != nil } ?? false },
            update: { update($0, rows: rows) },
            exit: { drag.end() },
            perform: perform))
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: rows.map(\.id))
        .sensoryFeedback(.impact(weight: .medium), trigger: commits)
    }

    private func item(_ row: TaskTree.Row) -> some View {
        let structure = TaskStructure(
            indent: tree.indent(row.id).map { move in { commit(row.id, move) } },
            outdent: tree.outdent(row.id).map { move in { commit(row.id, move) } })
        return line(row)
        .padding(.leading, CGFloat(row.depth) * Self.indentWidth)
        .background { DropHighlight(drag: drag, id: row.id) }
        .contentShape(.rect)
        .environment(\.taskStructure, structure)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(outlineSpace)) } action: { drag.frames[row.id] = $0 }
        .onDrag { TaskDragSession.shared.begin(row.id) }
        #if os(iOS)
        .rowSwipes(.card(row.task, workspace: workspace, structure: structure))
        #endif
    }

    private func update(_ point: CGPoint, rows: [TaskTree.Row]) {
        guard let dragged = TaskDragSession.shared.dragged else { return }
        let start = drag.startX ?? point.x
        drag.startX = start
        let shift = Int(((point.x - start) / Self.indentWidth).rounded())
        drag.set(whole.drop(dragged, rows: rows, frames: drag.frames, at: point, depthShift: shift, gaps: gaps))
    }

    /// 只落自己大纲里拖出来的那一条：拖进来的内容与它不符（比如别处拖来的文字）就不动。
    private func perform(_ info: DropInfo) -> Bool {
        let dragged = TaskDragSession.shared.dragged, move = drag.drop?.move
        TaskDragSession.shared.dragged = nil
        drag.end()
        guard let dragged, let move, let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let expected = dragged.uuidString
        let apply: @MainActor @Sendable () -> Void = { commit(dragged, move) }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let matches = (object as? NSString).map(String.init) == expected
            Task { @MainActor in if matches { apply() } }
        }
        return true
    }

    /// 任务挪到新位置。
    private func commit(_ id: UUID, _ move: TaskMove) {
        commits += 1
        workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
    }
}

/// 正被拖着的任务：一次只有一条，同一页上的几个大纲（看板的进行中与待办、项目页的任务区）都认它，所以能跨组拖。
/// 拖到页外取消时系统不通知，留着的旧值只会让下一次拖进来的外部内容被`perform`核对后拒绝。
final class TaskDragSession {
    static let shared = TaskDragSession()

    func begin(_ id: UUID) -> NSItemProvider {
        dragged = id
        return NSItemProvider(object: id.uuidString as NSString)
    }
    var dragged: UUID?
}

/// 一个大纲里的落点状态。起点与行的位置不参与排版（不观察）；落点只由高亮与插入线读，且只在变了时才写。
@Observable
private final class OutlineDrag {
    private(set) var drop: TaskDrop?
    /// 拖进这个大纲时的横坐标：横移从这里量。
    @ObservationIgnored var startX: CGFloat?
    @ObservationIgnored var frames: [UUID: CGRect] = [:]

    func set(_ next: TaskDrop?) {
        if drop != next { drop = next }
    }

    func end() {
        startX = nil
        set(nil)
    }
}

/// 停在这一行中部时的高亮（松手成为它的步骤）。
private struct DropHighlight: View {
    let drag: OutlineDrag
    let id: UUID
    @Environment(\.palette) private var palette

    var body: some View {
        if drag.drop?.mark == .onto(id) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.selection).padding(.horizontal, -6)
                .transition(.opacity)
        }
    }
}

/// 两行之间的落点：一条墨色线，起点是一个小圈，左边缩到落下后的层级；落点变化时一下轻触感。
private struct InsertionLine: View {
    let drag: OutlineDrag
    let first: UUID?
    let indent: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .topLeading) {
            if case .gap(let after, let depth) = drag.drop?.mark, let top = first.flatMap({ drag.frames[$0] }) {
                let y = after.flatMap { drag.frames[$0]?.maxY } ?? top.minY
                let x = CGFloat(depth) * indent
                HStack(spacing: 0) {
                    Circle().strokeBorder(palette.ink, lineWidth: 2).frame(width: 9, height: 9)
                    Capsule().fill(palette.ink).frame(height: 2)
                }
                .frame(width: max(top.maxX - x, 0))
                .offset(x: x, y: y - 4.5)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.quick, value: drag.drop?.mark)
        .sensoryFeedback(.selection, trigger: drag.drop?.mark) { _, mark in mark != nil }
    }
}

/// 大纲的落点：系统拖放每次移动报一次位置（大纲自己的坐标系）。
private struct OutlineDrop: DropDelegate {
    let accepts: () -> Bool
    let update: (CGPoint) -> Void
    let exit: () -> Void
    let perform: (DropInfo) -> Bool

    func validateDrop(info: DropInfo) -> Bool { accepts() }
    func dropEntered(info: DropInfo) { update(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { exit() }
    func performDrop(info: DropInfo) -> Bool { perform(info) }
}
