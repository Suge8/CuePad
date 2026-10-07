#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// Mac 的任务浮窗：点任务行弹出，与手机的任务浮窗同一个层级——顶上一行是状态与所在项目（右边"整页打开"）；正文是给 Agent 的话
/// （边写边存），贴着它右下是交给 Agent（发送目标同底部输入栏），只有标题时左边一句"写下要 Agent 做什么…"；下面是 Agent 与下级
/// 两行（`TaskSections`），点开就地展开。点下级在浮窗里换成它，左上角回到上级。
struct TaskPopover: View {
    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var shown: UUID?

    var body: some View {
        let id = shown ?? taskID
        TaskPopoverPage(cardID: id, back: id == taskID ? nil : { shown = nil }, openChild: { shown = $0 })
            .id(id)
            .frame(width: 460, height: 540)
            .background(palette.paper)
    }
}

private struct TaskPopoverPage: View {
    let cardID: UUID
    let back: (() -> Void)?
    let openChild: (UUID) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var card: Card?
    @State private var initialText: String?
    @State private var liveText = ""
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if card?.isTask == true {
                Text("给 Agent 的话").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink3).padding(.top, 4)
            }
            if let initialText {
                EditorHost(
                    initialText: initialText, theme: .paper(palette, horizontalInset: 0), handle: handle,
                    onChange: { next in
                        liveText = next
                        autosave?.changed(next)
                    },
                    onError: workspace.fail)
            }
            promptBar
            if let card, card.isTask {
                Divider().overlay(palette.hair)
                TaskSections(task: card, openChild: openChild)
            }
        }
        .padding(16)
        .observing(services.store, [.cards], id: cardID, into: $card, onError: workspace.fail) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return card
        }
        .onChange(of: card?.id, initial: true) {
            guard initialText == nil, let card else { return }
            initialText = card.body
            liveText = card.body
        }
        .onAppear(perform: makeAutosave)
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let back {
                Button("回到上级", systemImage: "chevron.left", action: back)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let card, card.isTask { TaskStatusMenu(task: card) }
            let project = workspace.catalog?.project(card?.projectID)
            ProjectGlyph(project: project, size: 12)
            Text(project?.name ?? "未归档").foregroundStyle(palette.ink3)
            if card?.isTask == false { Text("· 素材").foregroundStyle(palette.ink3) }
            Spacer()
            Button("整页打开", systemImage: "arrow.up.left.and.arrow.down.right") {
                workspace.overlay = nil
                workspace.openCard = cardID
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(palette.ink3)
            .help("整页打开")
        }
        .font(.system(size: 12))
    }

    /// 贴着正文的底边：任务只有标题时的引导，右边是交给 Agent。
    private var promptBar: some View {
        HStack(spacing: 8) {
            if card?.isTask == true, !TaskPrompt.isWritten(liveText) { PromptHint(action: handle.continueAtEnd) }
            Spacer()
            if let card {
                SendControl(project: card.projectID, compact: true) { choice in
                    let text = Outgoing.text(body: handle.text ?? liveText, values: card.variableValues), id = card.id
                    Task { await workspace.send(text, via: choice, card: id) }
                }
            }
        }
        .font(.system(size: 12))
    }

    private func makeAutosave() {
        guard autosave == nil else { return }
        let store = services.store, id = cardID
        autosave = Autosave(save: { body in try await store.updateCard(id) { $0.body = body } }, onError: workspace.fail)
    }
}

/// Mac 上任务正文周围的次要两行：Agent（交给的会话此刻在做什么、发出过几次）与下级（子任务与素材），点开就地展开。
/// 任务浮窗放在正文下面，纸页放在正文上面。
struct TaskSections: View {
    let task: Card
    var openChild: ((UUID) -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var detail: TaskDetail?
    @State private var showsSends = false
    @State private var showsChildren = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TaskAgentStrip(detail: detail) { withAnimation(Motion.quick) { showsSends.toggle() } }
            if showsSends { scrolling { SendRecordList(records: detail?.sends ?? []) } }
            TaskSubitemsRow(detail: detail, expanded: showsChildren) { withAnimation(Motion.quick) { showsChildren.toggle() } }
            if showsChildren { scrolling { TaskChildrenList(task: task, detail: detail, openChild: openChild) } }
        }
        .modifier(SessionDetailHost(arrowEdge: .bottom))
        .observing(services.store, TaskDetail.tables, id: task.id, into: $detail, onError: workspace.fail) { [id = task.id] in
            try TaskDetail.read(id, from: $0)
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 0, content: content).padding(.leading, TaskMetrics.labelWidth + 10) }
            .frame(maxHeight: 150)
            .transition(.opacity)
    }
}
#endif
