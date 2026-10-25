import CueStore
import SwiftUI

/// 任务气泡：看一条任务只有它（看板的卡、项目页的任务行、Cue 页里提到与做完的任务、⌘K 与选择器、归档、小组件链接，都经 `Workspace.openTask`；
/// 任务行与看板卡点开工了的叶子直接进会话，其余开它，`Workspace.enter`），
/// 内容两端同一份（`TaskBubblePage` 加最下面的"下一步" `BubbleFooter`），只有摆法分端（`TaskBubbleSlot`）。不换页、不压暗；点外面或 Esc 关。
/// 翻到一个子任务（点子任务行）原地换页、左上出返回；别处删掉、归档了它，气泡收起。
/// "下一步"：交给了会话是它此刻的样子（吉祥物、一句话），点了去会话；还没开始的叶子是"开始"（正文连同标题交给 Agent）；
/// 有子任务的看最该你看的那一步（`Workspace.lead`）。
struct TaskBubble: View {
    /// 一次打开：`id` 每次打开都不同（同一件事再点一次也从新的那一下长出来）；`step` 是翻到的子任务，翻页不换 `id`。
    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// 顶层任务。
        let task: UUID
        /// 翻到的子任务；nil 是这件事本身（有子任务时是子任务一览）。
        var step: UUID?
        /// 从哪长出来：点的那一下，或没有来源（`Workspace.openTask`）。
        let source: BubbleSource
    }

    let request: Request
    /// 摆成贴在底部的纸（手机）：顶上多一条把手（拖它往下关），下面让出 Home 指示条那一截。
    var sheet = false
    /// 翻到的那一步：跟着工作区里开着的这一次（翻页只改它）；这一次关了就停在最后一页，收起的那一下不跳回打开时的页。
    @State private var step: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @State private var data: BubbleData?
    /// 这一页的编辑：页一出现就开着（编辑器从第一帧就在，点哪写哪），翻页、关气泡先写下没保存的字再换。"开始"先等它落盘再交出去。
    @State private var editing: CardEditing?

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data, let editing, editing.cardID == data.focus(step).id {
                let focus = data.focus(step)
                VStack(alignment: .leading, spacing: BubbleMetrics.footerGap) {
                    #if os(iOS)
                    if sheet { SheetGrabber().padding(.bottom, -BubbleMetrics.footerGap) }
                    #endif
                    TaskBubblePage(data: data, focus: focus, editing: editing)
                    BubbleFooter(data: data, focus: focus, editing: editing)
                        .padding(.leading, BubbleMetrics.textLeading).padding(.trailing, BubbleMetrics.textTrailing)
                }
                .padding(BubbleMetrics.padding)
                .padding(.bottom, sheet ? BubbleMetrics.sheetBottom : 0)
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
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        .onChange(of: data?.focus(step).id, initial: true) { edit(data?.focus(step)) }
        .onChange(of: live, initial: true) { if let live { step = live.step } }
        .onDisappear { editing?.leave() }
    }

    /// 工作区里开着的正是这一次时的它。
    private var live: Request? { workspace.openTask?.id == request.id ? workspace.openTask : nil }

    private func edit(_ card: Card?) {
        guard editing?.cardID != card?.id else { return }
        editing?.leave()
        editing = card.map { CardEditing($0, titled: true, workspace: workspace) }
    }
}

/// 任务气泡挂在窗口上的那一格（Mac 主窗口、手机与 iPad 的根视图各挂一次）：只有它读 `Workspace.openTask`，开合、翻页时只重算它，不连带根视图。
/// 摆法分端：Mac 与宽屏 iPad 从点的那一下长出带尾巴的气泡；手机（窄屏）是贴在底部的纸（`BubbleSource.bottom`，拇指够得着"下一步"，拖把手往下关）。
/// 都画在气泡那一层（`PanelStyle.bubble`）：开合只挪图层；键盘升起时整块挪到键盘之上，字不重排（`BubbleStage.floor`）。
/// 手机不用系统 sheet（实测）：iOS 26 的纸在矮的那几档整张缩小约 3.5%、键盘一起就放回原大，字跟着缩放；开一次的指令数是自绘的近 3 倍、关一次十几倍。
struct TaskBubbleSlot: View {
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var workspace = workspace
        // 铺满：手机上气泡在这一层里摆（Mac 上画在窗口的浮层那一层，`panelHost`）
        let source = source
        Color.clear.panel(item: $workspace.openTask, style: .bubble(source)) { TaskBubble(request: $0, sheet: source == .bottom) }
    }

    private var source: BubbleSource {
        #if os(iOS)
        if sizeClass == .compact { return .bottom }
        #endif
        return workspace.openTask?.source ?? .unanchored
    }
}

/// 气泡一次读出的东西：顶层任务、它的子任务、它在看板的哪一列。
nonisolated struct BubbleData: Sendable, Equatable {
    var goal: Card
    var steps: [Card]
    /// 子任务完成了几个（`CueStore.subtaskProgress`）；没有子任务为 nil。
    var progress: TaskProgress?
    /// 在看板的哪一列（`TaskBoard.Column.of`，与看板同一条规则、同一份 `cueTally`）。
    var column: TaskBoard.Column
    /// 已不是一条看得见的任务（删了、归档了）。
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil }

    /// 翻到的那一页：那一步（还在时），否则这件事本身。
    func focus(_ step: UUID?) -> Card { steps.first { $0.id == step } ?? goal }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> BubbleData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        return BubbleData(
            goal: goal, steps: try store.children(of: id).filter(\.isTask),
            progress: try store.subtaskProgress(of: [id])[id], column: .of(goal, in: try store.cueTally()))
    }
}

/// 气泡里的字号、间距与尺寸：Mac 按指针，手机按手指（行高 44）。
/// 左边一列（`lead`，完成圈的点按区那么宽）里居中放列记号、完成圈、子任务的圈；字都从同一条竖线（`textLeading`）起。
enum BubbleMetrics {
    /// 子任务行的圈那一列比左边一列窄多少的一半：子任务行往右挪这么多，圈与完成圈同一条中线。
    static let stepLead: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.ringColumn) / 2
    /// 字的竖线：子任务行的圈列加它与字的空（`TaskLine`），标题、列名、下一步都对着它。
    static let textLeading: CGFloat = stepLead + TaskMetrics.ringColumn + TaskMetrics.columnGap
    /// 完成圈（点按区 `chipTarget` 宽）与标题之间：让标题的字落在 `textLeading`。
    static let titleGap: CGFloat = textLeading - TaskMetrics.chipTarget
    /// 贴在底部的纸（手机）下面让出的那一截（Home 指示条）。
    static let sheetBottom: CGFloat = 12
    #if os(macOS)
    static let strong = Typography.secondary.weight(.semibold)
    static let meta = Typography.meta
    static let padding = EdgeInsets(top: 6, leading: 10, bottom: 14, trailing: 6)
    static let laneMark: CGFloat = 16
    static let laneFont = Typography.secondary.weight(.semibold)
    static let titleSize: CGFloat = 17
    static let bodySize: CGFloat = 14
    static let editorInset: CGFloat = 6
    /// 标题第一行的中线对着完成圈的中线（截图核对）。
    static let ringTop: CGFloat = 2
    static let textTrailing: CGFloat = 12
    static let footerGap: CGFloat = 10
    static let gap: CGFloat = 10
    static let dot: CGFloat = 6
    static let mascot: CGFloat = 34
    static let capsule: CGFloat = 28
    static let stripPadding = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    static let stripRadius: CGFloat = 12
    #else
    static let strong = Font.subheadline.weight(.semibold)
    static let meta = Font.footnote
    static let padding = EdgeInsets(top: 6, leading: 8, bottom: 14, trailing: 8)
    static let laneMark: CGFloat = 20
    static let laneFont = Font.subheadline.weight(.semibold)
    static let titleSize: CGFloat = 20
    static let bodySize: CGFloat = 16
    static let editorInset: CGFloat = 10
    static let ringTop: CGFloat = 3
    static let textTrailing: CGFloat = 12
    static let footerGap: CGFloat = 12
    static let gap: CGFloat = 8
    static let dot: CGFloat = 7
    static let mascot: CGFloat = 40
    static let capsule: CGFloat = 36
    static let stripPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    static let stripRadius: CGFloat = 18
    #endif
}
