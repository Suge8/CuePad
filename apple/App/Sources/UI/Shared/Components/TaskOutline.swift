import CueStore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// 大纲自己的坐标系：行的位置与拖放的落点都在这里量。
private nonisolated let outlineSpace = "TaskOutline"

/// 一行任务在大纲里能做的结构操作；做不了的为 nil。行的长按/右键菜单（`TaskActions`）与读屏动作从环境里取。
struct TaskStructure {
    var indent: (() -> Void)?
    var outdent: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var taskStructure: TaskStructure?
}

/// 任务大纲（手机任务页与项目页、Mac 任务面板与项目页共用）：按 `TaskTree` 缩进排出可见的行，有子任务的行尾可折起展开（第三级默认折起）。
/// 手势用系统拖放（长按抬起、与长按菜单共存；Mac 按住拖）：停在一行中部高亮、松手成为它的子任务；停在两行之间出插入线，
/// 横向挪动改层级（插入线的起点跟着缩进）。手机上向右轻扫缩进、向左反缩进（过阈值有触感，松手生效）。落点规则全在 `TaskTree`，这里只管手势与画。
/// 行之间不让位（同提醒事项的插入线）：拖动期间不重排，也就不会每帧重算布局。
struct TaskOutline<Line: View>: View {
    private let tree: TaskTree
    private let line: (TaskTree.Row) -> Line
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toggled: Set<UUID> = []
    @State private var drag = OutlineDrag()
    @State private var commits = 0

    /// `roots`：只显示这些顶层任务及其子树（看板的一组、项目页的前几条），结构操作也只在里面算；nil 是全部。
    init(tree: TaskTree, roots: [UUID]? = nil, @ViewBuilder line: @escaping (TaskTree.Row) -> Line) {
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { item($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(outlineSpace))
        .overlay(alignment: .topLeading) { InsertionLine(drag: drag, first: rows.first?.id, indent: Self.indentWidth) }
        .onDrop(of: [.utf8PlainText], delegate: OutlineDrop(
            accepts: { drag.dragged != nil },
            update: { update($0, rows: rows) },
            exit: { drag.set(nil) },
            perform: perform))
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: rows.map(\.id))
        .sensoryFeedback(.impact(weight: .medium), trigger: commits)
    }

    private func item(_ row: TaskTree.Row) -> some View {
        let structure = TaskStructure(
            indent: tree.indent(row.id).map { move in { commit(row.id, move) } },
            outdent: tree.outdent(row.id).map { move in { commit(row.id, move) } })
        return HStack(spacing: 0) {
            line(row)
            if row.childCount > 0 { Disclosure(row: row, toggled: $toggled) }
        }
        .padding(.leading, CGFloat(row.depth) * Self.indentWidth)
        .background { DropHighlight(drag: drag, id: row.id) }
        .contentShape(.rect)
        .environment(\.taskStructure, structure)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(outlineSpace)) } action: { drag.frames[row.id] = $0 }
        .onDrag {
            drag.begin(row.id)
            return NSItemProvider(object: row.id.uuidString as NSString)
        }
        #if os(iOS)
        .modifier(IndentSwipe(structure: structure))
        #endif
    }

    private func update(_ point: CGPoint, rows: [TaskTree.Row]) {
        guard let dragged = drag.dragged else { return }
        let start = drag.startX ?? point.x
        drag.startX = start
        let shift = Int(((point.x - start) / Self.indentWidth).rounded())
        drag.set(tree.drop(dragged, rows: rows, frames: drag.frames, at: point, depthShift: shift))
    }

    /// 只落自己大纲里拖出来的那一条：拖进来的内容与它不符（比如别处拖来的文字）就不动。
    private func perform(_ info: DropInfo) -> Bool {
        let dragged = drag.dragged, move = drag.drop?.move
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

    private func commit(_ id: UUID, _ move: TaskMove) {
        commits += 1
        workspace.move(id, move)
    }
}

/// 一次拖动的状态。被拖的那条、起点与行的位置不参与排版（不观察）；落点只由高亮与插入线读，且只在变了时才写。
@Observable @MainActor
private final class OutlineDrag {
    private(set) var drop: TaskDrop?
    @ObservationIgnored private(set) var dragged: UUID?
    /// 第一次落在大纲上时的横坐标：横移从这里量。
    @ObservationIgnored var startX: CGFloat?
    @ObservationIgnored var frames: [UUID: CGRect] = [:]

    func begin(_ id: UUID) {
        dragged = id
        startX = nil
        set(nil)
    }

    func set(_ next: TaskDrop?) {
        if drop != next { drop = next }
    }

    func end() {
        dragged = nil
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

/// 行尾的折起/展开：折起时写子任务数。
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
            HStack(spacing: 3) {
                if !row.isExpanded { Text("\(row.childCount)").monospacedDigit() }
                Image(systemName: "chevron.right").fontWeight(.semibold).rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            }
            .font(.caption)
            .foregroundStyle(palette.ink3)
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #else
            .frame(minWidth: 24, minHeight: 22)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isExpanded ? "折起子任务" : "展开 \(row.childCount) 个子任务")
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

#if os(iOS)
/// 向右轻扫缩进、向左反缩进：行跟着手指走，露出缩进或反缩进的图标，过阈值有触感、图标变实，松手生效后回位。
/// 做不了的方向只给一点阻力、不露图标。只在横向明显快于纵向时接手，不抢列表滚动与屏幕边缘的返回手势。
private struct IndentSwipe: ViewModifier {
    let structure: TaskStructure
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var translation: CGFloat = 0

    private static let threshold: CGFloat = 56
    private static let reach: CGFloat = 88

    private var action: (() -> Void)? { translation > 0 ? structure.indent : translation < 0 ? structure.outdent : nil }
    private var armed: Bool { action != nil && abs(translation) >= Self.threshold }

    /// 能做的方向跟手（过阈值后放慢），做不了的方向只挪一点。
    private var offset: CGFloat {
        let distance = abs(translation)
        let shown = action == nil ? min(distance * 0.15, 12)
            : min(distance, Self.threshold) + max(distance - Self.threshold, 0) * 0.3
        return min(shown, Self.reach) * (translation < 0 ? -1 : 1)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: translation > 0 ? .leading : .trailing) {
                if action != nil, translation != 0 {
                    Image(systemName: translation > 0 ? "increase.indent" : "decrease.indent")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(armed ? palette.ink : palette.ink3)
                        .scaleEffect(armed ? 1 : 0.85)
                        .frame(width: abs(offset), alignment: .center)
                        .opacity(min(abs(offset) / Self.threshold, 1))
                        .accessibilityHidden(true)
                }
            }
            .gesture(HorizontalPan(changed: { translation = $0 }, ended: end))
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { !$0 && $1 }
            .animation(Motion.quick, value: armed)
    }

    private func end() {
        if armed { action?() }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { translation = 0 }
    }
}

/// 只接横向的拖：开始时横向速度明显大于纵向、且不在屏幕左缘（那里是返回手势）才开始。
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let edge: CGFloat = 28

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5 && pan.location(in: nil).x > Self.edge
        }
    }
}
#endif
