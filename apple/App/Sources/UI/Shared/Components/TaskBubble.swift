import CueStore
import SwiftUI

struct TaskBubble: View {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let task: UUID
        var step: UUID?
        let source: BubbleSource
    }

    let request: Request
    var sheet = false
    @State private var step: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: BubbleData?
    @State private var editing: CardEditing?

    var body: some View {
        Group {
            pages
            if let data, let editing, editing.cardID == data.focus(step).id {
                BubbleFooter(data: data, focus: data.focus(step), editing: editing)
                    .padding(.leading, Spacing.group).padding(.trailing, ComposerMetrics.glyphInset)
                    .padding(.top, BubbleMetrics.footerGap - Spacing.item)
                    .padding(.bottom, ComposerMetrics.glyphInset + (sheet ? BubbleMetrics.sheetBottom : 0))
                    .bubbleFoot()
            }
        }
        #if os(macOS)
        .modifier(WindowCardAgents(workspace: workspace))
        #endif
    }

    private var pages: some View {
        // 是一个容器而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始；翻页的两页叠在 `TurnStack` 里（`Motion.turn`）
        TurnStack {
            if let data, let editing, editing.cardID == data.focus(step).id {
                let focus = data.focus(step)
                VStack(alignment: .leading, spacing: BubbleMetrics.footerGap) {
                    #if os(iOS)
                    if sheet { SheetGrabber().padding(.bottom, -BubbleMetrics.footerGap) }
                    #endif
                    TaskBubblePage(data: data, focus: focus, editing: editing)
                    ForEach(data.schedules.filter { $0.line.task == focus.id }) { ScheduleStrip(scheduled: $0) }
                        .padding(.leading, BubbleMetrics.textLeading).padding(.trailing, BubbleMetrics.textTrailing)
                }
                .padding(.vertical, Spacing.item).padding(.leading, BubbleMetrics.leading)
                .id(focus.id)
                .transition(Motion.turn(from: step == nil ? .leading : .trailing, reduceMotion: reduceMotion))
            }
        }
        .debugCyclesTurn { if let data { workspace.openTask(step == nil ? data.steps.first ?? data.goal : data.goal) } }
        .observing(services.store, id: request.task, into: $data, onError: workspace.fail) { [task = request.task] in try BubbleData.read(task, from: $0) }
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        .onChange(of: data?.focus(step).id, initial: true) { edit(data?.focus(step)) }
        .onChange(of: live, initial: true) {
            guard let live, live.step != step || editing == nil else { return }
            withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) {
                step = live.step
                edit(data?.focus(step))
            }
        }
        .onDisappear { editing?.leave() }
    }

    private var live: Request? { workspace.openTask?.id == request.id ? workspace.openTask : nil }

    private func edit(_ card: Card?) {
        guard editing?.cardID != card?.id else { return }
        editing?.leave()
        editing = card.map { CardEditing($0, titled: true, workspace: workspace) }
    }
}

/// 只有它读 `Workspace.openTask`，开合、翻页时只重算它，不连带根视图。
/// 手机不用系统 sheet（实测）：iOS 26 的纸在矮的那几档整张缩小约 3.5%、键盘一起就放回原大，字跟着缩放；开一次的指令数是自绘的近 3 倍、关一次十几倍。
struct TaskBubbleSlot: View {
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var workspace = workspace
        let source = source
        Color.clear.panel(item: $workspace.openTask, style: .bubble(source, width: .fixed(BubbleMetrics.width))) { TaskBubble(request: $0, sheet: source == .bottom) }
    }

    private var source: BubbleSource {
        #if os(iOS)
        if sizeClass == .compact { return .bottom }
        #endif
        return workspace.openTask?.source ?? .unanchored
    }
}

nonisolated struct BubbleData: Sendable, Equatable {
    var goal: Card
    var steps: [Card]
    var progress: TaskProgress?
    var column: TaskBoard.Column
    var schedules: [CueScheduled]
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil }

    func focus(_ step: UUID?) -> Card { steps.first { $0.id == step } ?? goal }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> BubbleData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        let steps = try store.children(of: id).filter(\.isTask), ids = Set([id] + steps.map(\.id))
        return BubbleData(
            goal: goal, steps: steps, progress: try store.subtaskProgress(of: [id])[id], column: .of(goal, in: try store.cueTally()),
            schedules: try store.cueSchedules().filter { $0.line.task.map(ids.contains) == true })
    }
}

enum BubbleMetrics {
    static let stepLead: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.ringColumn) / 2
    static let ringInset: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.titleRing) / 2
    static let leading = Spacing.group - ringInset
    static let textLeading: CGFloat = stepLead + TaskMetrics.ringColumn + TaskMetrics.columnGap
    static let titleGap: CGFloat = textLeading - TaskMetrics.chipTarget
    static let textTrailing = Spacing.block
    static let sheetBottom = Spacing.group
    #if os(macOS)
    static let strong = Typography.secondaryBold
    static let meta = Typography.meta
    static let editorInset = Spacing.glyph
    static let ringTop: CGFloat = 2
    static let footerGap = Spacing.item
    static let gap = Spacing.item
    static let brand: CGFloat = 20
    static let markSlot: CGFloat = 26
    static let dot: CGFloat = 8
    static let capsule: CGFloat = 28
    static let width: CGFloat = 480
    static let stripPadding = EdgeInsets(top: Spacing.item, leading: Spacing.item, bottom: Spacing.item, trailing: Spacing.item)
    #else
    static let strong = Typography.secondaryBold
    static let meta = Typography.meta
    static let editorInset = Spacing.item
    static let ringTop: CGFloat = 3
    static let footerGap = Spacing.group
    static let gap = Spacing.item
    static let brand: CGFloat = 24
    static let markSlot: CGFloat = 32
    static let dot: CGFloat = 9
    static let capsule: CGFloat = 36
    static let width = BubblePlacement.maxWidth
    static let stripPadding = EdgeInsets(top: Spacing.item, leading: Spacing.item, bottom: Spacing.item, trailing: Spacing.item)
    #endif
}
