import CueStore
import SwiftUI

/// 看一条任务只有它，各处都经 `Workspace.openTask`；任务行与看板卡点开工了的叶子直接进会话，其余开它（`Workspace.enter`）。
struct TaskBubble: View {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let task: UUID
        var step: UUID?
        let source: BubbleSource
    }

    let request: Request
    var sheet = false
    /// 翻到的那一步：跟着工作区里开着的这一次（翻页只改它）；这一次关了就停在最后一页，收起的那一下不跳回打开时的页。
    @State private var step: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: BubbleData?
    /// 这一页的编辑：页一出现就开着（编辑器从第一帧就在，点哪写哪），翻页、关气泡先写下没保存的字再换。"开始"先等它落盘再交出去。
    @State private var editing: CardEditing?

    var body: some View {
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
                    BubbleFooter(data: data, focus: focus, editing: editing)
                        #if os(iOS)
                        .padding(.leading, BubbleMetrics.textLeading).padding(.trailing, BubbleMetrics.textTrailing)
                        #else
                        .padding(.trailing, Spacing.hair)
                        #endif
                }
                .padding(BubbleMetrics.padding)
                .padding(.bottom, sheet ? BubbleMetrics.sheetBottom : 0)
                .id(focus.id)
                .transition(Motion.turn(from: step == nil ? .leading : .trailing, reduceMotion: reduceMotion))
            }
        }
        .debugCyclesTurn { if let data { workspace.openTask(step == nil ? data.steps.first ?? data.goal : data.goal) } }
        #if os(macOS)
        // Mac 的浮层挂在页面之外：子任务的状态点、"下一步"读的"交给了哪个会话"在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        #endif
        .observing(services.store, id: request.task, into: $data, onError: workspace.fail) { [task = request.task] in try BubbleData.read(task, from: $0) }
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        .onChange(of: data?.focus(step).id, initial: true) { edit(data?.focus(step)) }
        // 翻页时编辑跟着在同一次更新里换好：等焦点变了再换的话，旧页先撤、新页晚一次更新才插进来，气泡先塌下去再长出来
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
    static let textLeading: CGFloat = stepLead + TaskMetrics.ringColumn + TaskMetrics.columnGap
    static let titleGap: CGFloat = textLeading - TaskMetrics.chipTarget
    static let sheetBottom = Spacing.group
    #if os(macOS)
    static let strong = Typography.secondary.weight(.semibold)
    static let meta = Typography.meta
    static let padding = EdgeInsets(top: 6, leading: Spacing.item, bottom: Spacing.group, trailing: 6)
    static let laneMark: CGFloat = 16
    static let laneFont = Typography.secondary.weight(.semibold)
    static let editorInset: CGFloat = 6
    static let ringTop: CGFloat = 2
    static let textTrailing = Spacing.group
    static let footerGap = Spacing.item
    static let gap = Spacing.item
    static let brand: CGFloat = 20
    static let markSlot: CGFloat = 26
    static let dot: CGFloat = 8
    static let capsule: CGFloat = 28
    /// 同新会话的输入框一样宽（`NewSessionInput`）：底下那一排（哪家、模型、思考强度、"开始"）的字都写得全。
    static let width: CGFloat = 480
    static let stripPadding = EdgeInsets(top: Spacing.item, leading: Spacing.item, bottom: Spacing.item, trailing: Spacing.item)
    #else
    static let strong = Typography.secondary.weight(.semibold)
    static let meta = Typography.meta
    static let padding = EdgeInsets(top: 6, leading: Spacing.item, bottom: Spacing.group, trailing: Spacing.item)
    static let laneMark: CGFloat = 20
    static let laneFont = Typography.secondary.weight(.semibold)
    static let editorInset = Spacing.item
    static let ringTop: CGFloat = 3
    static let textTrailing = Spacing.group
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
