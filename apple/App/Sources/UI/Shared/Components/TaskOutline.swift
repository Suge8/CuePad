import CueStore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension View {
    /// 灵感可以拖到任务大纲的任务行上，松手成为它的提示词（iOS 长按抬起，Mac 按住拖）。
    func ideaDrag(_ id: UUID) -> some View {
        onDrag { TaskDragSession.shared.begin(id, isTask: false) }
    }
}

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

/// 任务大纲（手机任务页与项目页、Mac 任务面板与项目页共用）：按 `TaskTree` 缩进排出可见的行，有下级的行尾可折起展开（默认展开；
/// 哪些行算有下级由 `folds` 定：手机只看子任务，Mac 的行里还列着提示词）。
/// 手势用系统拖放（长按抬起、与长按菜单共存；Mac 按住拖）：停在一行中部高亮、松手成为它的子任务；停在两行之间出插入线，
/// 横向挪动改层级（插入线的起点跟着缩进）。手机上轻扫按 `CardMenu.swipes`：右滑缩进，左滑删除与反缩进（`rowSwipes`）。落点规则全在 `TaskTree`，这里只管手势与画。
/// 行之间不让位（同提醒事项的插入线）：拖动期间不重排，也就不会每帧重算布局。
struct TaskOutline<Line: View>: View {
    /// 整个看板（或项目页）的层级：拖放落点按它算，所以能从别的组拖进来。
    private let whole: TaskTree
    /// 这个大纲显示的范围：行、缩进与反缩进按它算。
    private let tree: TaskTree
    private let line: (TaskTree.Row) -> Line
    private let folds: (TaskTree.Row) -> Bool
    /// 行按需建（只建看得见的）：外面给了固定高度的滚动区、行数多到一屏放不下时用，否则整列的行都要在打开的那一圈里量一遍。
    private let lazy: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toggled: Set<UUID> = []
    @State private var drag = OutlineDrag()
    @State private var commits = 0

    /// `roots`：只显示这些顶层任务及其子树（看板的一组、项目页的前几条），结构操作也只在里面算；nil 是全部。
    init(
        tree: TaskTree, roots: [UUID]? = nil, lazy: Bool = false, folds: @escaping (TaskTree.Row) -> Bool = { $0.childCount > 0 },
        @ViewBuilder line: @escaping (TaskTree.Row) -> Line
    ) {
        self.lazy = lazy
        self.folds = folds
        whole = tree
        self.tree = roots.map(tree.scoped(to:)) ?? tree
        self.line = line
    }

    #if os(iOS)
    static var indentWidth: CGFloat { 24 }
    #else
    static var indentWidth: CGFloat { 18 }
    #endif

    // 视图体不读落点（拖动时每移一下都变）：只有高亮与插入线两个小视图读它，拖动期间列表本身不重算
    var body: some View {
        let rows = tree.rows(toggled: toggled)
        let list = ForEach(rows) { item($0) }
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { list }
            } else {
                VStack(alignment: .leading, spacing: 0) { list }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(outlineSpace))
        .overlay(alignment: .topLeading) { InsertionLine(drag: drag, first: rows.first?.id, indent: Self.indentWidth) }
        .onDrop(of: [.utf8PlainText], delegate: OutlineDrop(
            accepts: { TaskDragSession.shared.dragged.map { !$0.isTask || whole.task($0.id) != nil } ?? false },
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
        // 箭头对齐行的第一排（Mac 的行下面还列着提示词）
        return HStack(alignment: .top, spacing: 0) {
            line(row)
            if folds(row) { Disclosure(row: row, toggled: $toggled) }
        }
        .padding(.leading, CGFloat(row.depth) * Self.indentWidth)
        .background { DropHighlight(drag: drag, id: row.id) }
        .contentShape(.rect)
        .environment(\.taskStructure, structure)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(outlineSpace)) } action: { drag.frames[row.id] = $0 }
        .onDrag { TaskDragSession.shared.begin(row.id, isTask: true) }
        #if os(iOS)
        .rowSwipes(.card(row.task, workspace: workspace, structure: structure))
        #endif
    }

    private func update(_ point: CGPoint, rows: [TaskTree.Row]) {
        guard let dragged = TaskDragSession.shared.dragged else { return }
        guard dragged.isTask else { return drag.set(whole.drop(idea: dragged.id, rows: rows, frames: drag.frames, at: point)) }
        let start = drag.startX ?? point.x
        drag.startX = start
        let shift = Int(((point.x - start) / Self.indentWidth).rounded())
        drag.set(whole.drop(dragged.id, rows: rows, frames: drag.frames, at: point, depthShift: shift))
    }

    /// 只落自己大纲里拖出来的那一条：拖进来的内容与它不符（比如别处拖来的文字）就不动。
    private func perform(_ info: DropInfo) -> Bool {
        let dragged = TaskDragSession.shared.dragged, move = drag.drop?.move
        TaskDragSession.shared.dragged = nil
        drag.end()
        guard let dragged, let move, let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let expected = dragged.id.uuidString
        let apply: @MainActor @Sendable () -> Void = { commit(dragged, move) }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let matches = (object as? NSString).map(String.init) == expected
            Task { @MainActor in if matches { apply() } }
        }
        return true
    }

    private func commit(_ id: UUID, _ move: TaskMove) {
        commit(TaskDragSession.Dragged(id: id, isTask: true), move)
    }

    /// 任务挪到新位置；灵感成为提示词（提示里可撤销）。
    private func commit(_ dragged: TaskDragSession.Dragged, _ move: TaskMove) {
        commits += 1
        if dragged.isTask {
            workspace.perform { try await $0.moveCard(dragged.id, to: move.slot, after: move.after) }
        } else {
            workspace.attempt { try await workspace.attach(dragged.id, move) }
        }
    }
}

/// 正被拖着的任务或灵感：一次只有一条，同一页上的几个大纲（看板的进行中与待办、项目页的任务区）都认它，所以能跨组拖，
/// 灵感能从墙上拖到任务上。拖到页外取消时系统不通知，留着的旧值只会让下一次拖进来的外部内容被`perform`核对后拒绝。
final class TaskDragSession {
    struct Dragged {
        let id: UUID
        let isTask: Bool
    }

    static let shared = TaskDragSession()

    func begin(_ id: UUID, isTask: Bool) -> NSItemProvider {
        dragged = Dragged(id: id, isTask: isTask)
        return NSItemProvider(object: id.uuidString as NSString)
    }
    var dragged: Dragged?
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

/// 停在这一行中部时的高亮（松手成为它的子任务）。
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

/// 行尾的折起/展开：只是一个箭头。下级的数写在这一行的元信息里（"2 条提示词 · 子任务 0/2"），折起时不在箭头旁再写一个光秃秃的数。
private struct Disclosure: View {
    let row: TaskTree.Row
    @Binding var toggled: Set<UUID>
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) {
                if toggled.contains(row.id) { toggled.remove(row.id) } else { toggled.insert(row.id) }
            }
        } label: {
            Image(systemName: "chevron.right").fontWeight(.semibold).rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            .font(Typography.caption)
            .foregroundStyle(palette.ink3)
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #else
            .frame(minWidth: 24, minHeight: TaskMetrics.rowHeight)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isExpanded ? "折起" : "展开")
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
