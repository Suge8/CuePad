import CueStore
import SwiftUI

/// 任务气泡：点一条任务（项目页与进展页的行、Cue 对话里提到的任务、⌘K、归档、小组件链接），从点的那一下长出来的一张纸
/// （\`BubbleFrame\`，Mac 与手机同一个视图，只差字号与行高）。不换页、不压暗；点外面或 Esc 关，点外面另一条就换成它的气泡。
/// 上面是这件事：完成圈（有子任务时按子任务分段，做到哪只画在圈上）、标题（就地改）、"⋯"，一行所在项目，下面是它的正文（标题下面要交代给 Agent 的话，点了就地写）；
/// 有子任务时列出子任务（同全 App 的任务行 \`TaskLine\`），点一步气泡原地翻到这一步、左上出返回；顶层任务末尾一行添加子任务。
/// 最下面一条是"下一步"：交给了会话是它此刻的样子（吉祥物、一句话），点了去会话；还没开始的叶子是"开始"（正文连同标题交给 Agent）；
/// 有子任务的看最该你看的那一步（\`Workspace.lead\`）。
struct TaskBubble: View {
    /// 一次打开：\`id\` 每次打开都不同（同一件事再点一次也从新的那一下长出来）；\`step\` 是翻到的子任务，翻页不换 \`id\`。
    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// 顶层任务。
        let task: UUID
        /// 翻到的子任务；nil 是这件事本身（有子任务时是子任务一览）。
        var step: UUID?
        /// 从哪长出来：点的那一下，或没有来源（\`Workspace.openTask\`）。
        let source: BubbleSource
    }

    let request: Request
    /// 翻到的那一步：跟着工作区里开着的这一次（翻页只改它）；这一次关了就停在最后一页，收起的那一下不跳回打开时的页。
    @State private var step: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @State private var data: BubbleData?
    /// 正文正在写（点了正文之后才建编辑器：打开气泡不建它）。"开始"先等它落盘再交出去。
    @State private var editing: CardEditing?

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data {
                let focus = data.focus(step)
                BubblePage(data: data, focus: focus, editing: $editing)
                    .id(focus.id)
                    .transition(.opacity)
            }
        }
        .animation(HandOff.quick, value: step)
        #if os(macOS)
        // Mac 的浮层挂在页面之外：子任务的状态点、"下一步"读的"交给了哪个会话"在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        #endif
        .observing(services.store, id: request.task, into: $data, onError: workspace.fail) { [task = request.task] in try BubbleData.read(task, from: $0) }
        // 别处删掉、归档了它：气泡收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        // 翻页、关气泡都先写下正文里没保存的字
        .onChange(of: step) { leaveEditing() }
        .onChange(of: live, initial: true) { if let live { step = live.step } }
        .onDisappear(perform: leaveEditing)
    }

    /// 工作区里开着的正是这一次时的它。
    private var live: Request? { workspace.openTask?.id == request.id ? workspace.openTask : nil }

    private func leaveEditing() {
        editing?.leave()
        editing = nil
    }
}

/// 任务气泡挂在窗口上的那一格（Mac 主窗口、手机根视图各挂一次）：只有它读 `Workspace.openTask`，开合、翻页时只重算它，不连带根视图。
struct TaskBubbleSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        // 铺满：手机上气泡在这一层里摆（Mac 上画在窗口的浮层那一层，`panelHost`）
        Color.clear
            .panel(item: $workspace.openTask, style: .bubble(workspace.openTask?.source ?? .unanchored)) { TaskBubble(request: $0) }
    }
}

/// 气泡一次读出的东西：顶层任务、所在项目、它的子任务。
nonisolated struct BubbleData: Sendable, Equatable {
    var goal: Card
    var project: Project?
    var steps: [Card]
    /// 子任务完成了几个（\`CueStore.subtaskProgress\`）；没有子任务为 nil。
    var progress: TaskProgress?
    /// 已不是一条看得见的任务（删了、归档了）。
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil }

    /// 翻到的那一页：那一步（还在时），否则这件事本身。
    func focus(_ step: UUID?) -> Card { steps.first { $0.id == step } ?? goal }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> BubbleData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        return BubbleData(
            goal: goal, project: try store.project(goal.projectID), steps: try store.children(of: id).filter(\.isTask),
            progress: try store.subtaskProgress(of: [id])[id])
    }
}

/// 气泡里的字号、间距与尺寸：Mac 按指针，手机按手指（行高 44）。
enum BubbleMetrics {
    #if os(macOS)
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Typography.body
    static let strong = Typography.secondary.weight(.semibold)
    static let meta = Typography.meta
    static let padding = EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 16)
    static let gap: CGFloat = 10
    static let ringNudge: CGFloat = 1
    static let ringBleed: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.titleRing) / 2
    /// 标题、项目行、正文与子任务的圈都对齐到标题的字起点。
    static let indent: CGFloat = TaskMetrics.chipTarget - ringBleed + gap
    /// 子任务行的圈在它那一列（`TaskMetrics.ringColumn`）里居中：行往左挪半列空白，圈对着标题的字起点。
    static let rowLead: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    static let section: CGFloat = 10
    static let lineSpacing: CGFloat = Typography.lineSpacing
    static let previewLines = 6
    static let editorHeight: CGFloat = 120
    static let editorInset: CGFloat = 6
    static let editorRadius: CGFloat = 10
    static let glyph: CGFloat = 11
    static let moreTarget: CGFloat = 26
    static let backHeight: CGFloat = 22
    static let dot: CGFloat = 6
    static let mascot: CGFloat = 34
    static let capsule: CGFloat = 28
    static let stripPadding = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    static let stripRadius: CGFloat = 12
    #else
    static let title = Font.title3.weight(.semibold)
    static let body = Font.body
    static let strong = Font.subheadline.weight(.semibold)
    static let meta = Font.footnote
    static let padding = EdgeInsets(top: 20, leading: 18, bottom: 16, trailing: 16)
    static let gap: CGFloat = 8
    static let ringNudge: CGFloat = -10
    static let ringBleed: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.titleRing) / 2
    static let indent: CGFloat = TaskMetrics.chipTarget - ringBleed + gap
    static let rowLead: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    static let section: CGFloat = 8
    static let lineSpacing: CGFloat = 3
    static let previewLines = 6
    static let editorHeight: CGFloat = 150
    static let editorInset: CGFloat = 10
    static let editorRadius: CGFloat = 14
    static let glyph: CGFloat = 12
    static let moreTarget: CGFloat = 44
    static let backHeight: CGFloat = 36
    static let dot: CGFloat = 7
    static let mascot: CGFloat = 40
    static let capsule: CGFloat = 36
    static let stripPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    static let stripRadius: CGFloat = 18
    #endif
}
