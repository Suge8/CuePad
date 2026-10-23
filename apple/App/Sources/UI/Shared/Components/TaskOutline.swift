import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// 大纲自己的坐标系：行的位置与拖放的落点都在这里量。
private nonisolated let outlineSpace = "TaskOutline"

/// 一行任务在大纲里能做的结构操作；做不了的为 nil。手机上缩进进轻扫与同源的读屏动作（`RowSwipes.card`），任务行从环境里取来放进读屏动作（`spoken`）；做什么只在 `CardMenu.Item.run`。
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
/// 横向挪动改层级（插入线的起点跟着缩进）。拖来的是灵感（墙上的卡）时没有行间：指针下的那一行整行亮起，松手灵感接到它的正文后面（`Workspace.mergeIdea`）。
/// 手机上轻扫按 `CardMenu.swipes`：右滑缩进，左滑删除与"更多"（`rowSwipes`）。落点规则全在 `TaskTree`，这里只管手势与画。
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
            accepts: { CardDragSession.shared.idea != nil || CardDragSession.shared.task.map { whole.task($0) != nil } ?? false },
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
        .overlay { IdeaDropMark(drag: drag, id: row.id) }
        .contentShape(.rect)
        .environment(\.taskStructure, structure)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(outlineSpace)) } action: { drag.frames[row.id] = $0 }
        .onDrag { CardDragSession.shared.begin(.task(row.id)) }
        #if os(iOS)
        .rowSwipes(.card(row.task, workspace: workspace, structure: structure))
        #endif
    }

    private func update(_ point: CGPoint, rows: [TaskTree.Row]) {
        if CardDragSession.shared.idea != nil {
            return drag.setIdea(rows.first { drag.frames[$0.id]?.contains(point) == true }?.id)
        }
        guard let dragged = CardDragSession.shared.task else { return }
        let start = drag.startX ?? point.x
        drag.startX = start
        let shift = Int(((point.x - start) / Self.indentWidth).rounded())
        drag.set(whole.drop(dragged, rows: rows, frames: drag.frames, at: point, depthShift: shift))
    }

    /// 只落这次拖起的那一条：拖进来的内容与它不符（比如别处拖来的文字）就不动。
    private func perform(_ info: DropInfo) -> Bool {
        let dragged = CardDragSession.shared.dragged, move = drag.drop?.move, target = drag.idea
        CardDragSession.shared.end()
        drag.end()
        guard let dragged, let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let apply: @MainActor @Sendable () -> Void
        switch dragged {
        case .idea(let idea):
            guard let target else { return false }
            apply = { workspace.attempt { try await workspace.mergeIdea(idea, into: target) } }
        case .task(let task):
            guard let move else { return false }
            apply = { commit(task, move) }
        }
        let expected = dragged.id.uuidString
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let matches = (object as? NSString).map(String.init) == expected
            Task { @MainActor in if matches { apply() } }
        }
        return true
    }

    private func commit(_ id: UUID, _ move: TaskMove) {
        commits += 1
        workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
    }
}

/// 正被拖着的那一条：一次只有一条，同一页上的几个大纲都认它，所以任务能跨大纲拖，灵感（墙上的卡）能拖进任意一个大纲。
/// 拖到页外取消时系统不通知，留着的旧值只会让下一次拖进来的外部内容被`perform`核对后拒绝。
final class CardDragSession {
    enum Dragged: Equatable {
        case task(UUID), idea(UUID)

        var id: UUID {
            switch self {
            case .task(let id), .idea(let id): id
            }
        }
    }

    static let shared = CardDragSession()
    private(set) var dragged: Dragged?

    func begin(_ dragged: Dragged) -> NSItemProvider {
        self.dragged = dragged
        return NSItemProvider(object: dragged.id.uuidString as NSString)
    }

    func end() { dragged = nil }

    var task: UUID? { if case .task(let id) = dragged { id } else { nil } }
    var idea: UUID? { if case .idea(let id) = dragged { id } else { nil } }
}

/// 一个大纲里的落点状态。起点与行的位置不参与排版（不观察）；落点只由高亮与插入线读，且只在变了时才写。
@Observable
private final class OutlineDrag {
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
}

/// 停在这一行中部时的高亮（松手成为它的子任务）：行的选中底（`RowStyle`）。单拆一个视图，拖动时只有它跟着落点重算。
private struct DropHighlight: View {
    let drag: OutlineDrag
    let id: UUID

    var body: some View {
        Color.clear.row(selected: drag.drop?.mark == .onto(id)).allowsHitTesting(false)
    }
}

/// 拖着灵感停在这一行上：整行铺选中底、描一圈签名色，行尾一枚小签写松手会怎样（接到正文后面）。盖在行上，不改排版。
private struct IdeaDropMark: View {
    let drag: OutlineDrag
    let id: UUID
    @Environment(\.palette) private var palette
    @Environment(\.rowSurface) private var surface

    var body: some View {
        let on = drag.idea == id
        ZStack(alignment: .trailing) {
            if on {
                Color.clear.row(selected: true)
                RoundedRectangle(cornerRadius: RowMetrics.radius, style: .continuous)
                    .strokeBorder(palette.signature, lineWidth: 1.5)
                    .padding(.horizontal, -RowMetrics.bleed)
                // 实底的小签盖在行尾的旁注（时间、"开始"）上，字不叠字
                Label("接到正文后面", icon: .add).labelStyle(.titleAndIcon)
                    .font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.signature)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(surface ?? palette.paper, in: .capsule)
            }
        }
        .allowsHitTesting(false)
        .animation(HandOff.quick, value: on)
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
        .animation(HandOff.quick, value: drag.drop?.mark)
        .sensoryFeedback(.selection, trigger: drag.drop?.mark) { _, mark in mark != nil }
        // 拖着灵感换了一行：同一下轻触感（整行的亮起画在行上，`IdeaDropMark`）
        .sensoryFeedback(.selection, trigger: drag.idea) { _, row in row != nil }
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
