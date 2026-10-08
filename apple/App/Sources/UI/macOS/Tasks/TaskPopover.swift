#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// Mac 的任务浮窗：点任务行弹出，与手机的任务浮窗同样三块——① 标题行（完成圈、正文第一行就是标题、"⋯"与"整页打开"）；
/// ② 给 Agent 的话（边写边存）与它下面唯一的主按钮交给 Agent（发送目标同底部输入栏），有相关灵感或资料时上面一行可勾的小胶囊；
/// ③ 进展（`TaskProgressList`）。点下级在浮窗里换成它，左上角回到上级；"⋯"里的发出记录就地展开。
struct TaskPopover: View {
    let taskID: UUID
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
    @State private var detail: TaskDetail?
    @State private var left: Set<UUID> = []
    @State private var withResources = false
    @State private var showsSends = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let back {
                Button("回到上级", systemImage: "chevron.left", action: back)
                    .labelStyle(.titleAndIcon).buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(palette.ink3)
            }
            HStack(alignment: .top, spacing: 4) {
                if let card, card.isTask { TaskRingButton(task: card, marks: detail?.marks).padding(.top, 2) }
                if let initialText {
                    EditorHost(
                        initialText: initialText, theme: .paper(palette, horizontalInset: 0), handle: handle,
                        onChange: { next in
                            liveText = next
                            autosave?.changed(next)
                        },
                        onError: workspace.fail)
                }
                corner
            }
            if card?.isTask == true, !TaskPrompt.isWritten(liveText) { PromptHint(action: handle.continueAtEnd) }
            if card?.isTask == true { BundlePicker(detail: detail, left: $left, withResources: $withResources) }
            handBar
            if let card, card.isTask {
                if showsSends {
                    ScrollView { VStack(alignment: .leading, spacing: 0) { SendRecordList(records: detail?.sends ?? []) } }
                        .frame(maxHeight: 120)
                }
                Divider().overlay(palette.hair)
                ScrollView { TaskProgressList(task: card, detail: detail, openChild: openChild) }
                    .frame(maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .modifier(SessionDetailHost(arrowEdge: .bottom))
        .observing(services.store, TaskDetail.tables, id: cardID, into: $detail, onError: workspace.fail) { [cardID] in
            try TaskDetail.read(cardID, from: $0)
        }
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

    /// 右上："⋯"（`CardMenu.more`）与整页打开。
    private var corner: some View {
        HStack(spacing: 2) {
            if let card {
                Menu("更多", systemImage: "ellipsis") {
                    CardActions(card: card, more: true) { withAnimation(Motion.quick) { showsSends.toggle() } }
                }
                .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            }
            Button("整页打开", systemImage: "arrow.up.left.and.arrow.down.right") {
                workspace.overlay = nil
                workspace.openCard = cardID
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("整页打开")
        }
        .foregroundStyle(palette.ink3)
    }

    /// 唯一的主按钮：交给 Agent（目标同底部输入栏，带上选中的相关灵感与资料）。
    private var handBar: some View {
        HStack {
            Spacer()
            if let card {
                SendControl(project: card.projectID, compact: true) { choice in
                    let parts = card.isTask ? BundlePicker.parts(detail, left: left, withResources: withResources) : []
                    let body = Outgoing.text(body: handle.text ?? liveText, values: card.variableValues)
                    let text = TaskBundle.text(task: body, parts: parts), id = card.id, partIDs = parts.map(\.id)
                    Task { await workspace.send(text, via: choice, card: id, parts: partIDs) }
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

/// Mac 纸页上任务正文上方的一块：完成圈与进展（`TaskProgressList`）。
struct TaskPageHeader: View {
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var detail: TaskDetail?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TaskRingButton(task: task, marks: detail?.marks)
            TaskProgressList(task: task, detail: detail)
        }
        .modifier(SessionDetailHost(arrowEdge: .bottom))
        .observing(services.store, TaskDetail.tables, id: task.id, into: $detail, onError: workspace.fail) { [id = task.id] in
            try TaskDetail.read(id, from: $0)
        }
    }
}
#endif
