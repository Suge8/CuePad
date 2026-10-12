#if os(macOS)
import CueStore
import SwiftUI

/// 任务浮窗：点任务或它的提示词（项目页的任务区、任务面板、⌘K、归档）就在当前页上弹出，不换页。左右两栏，像邮件：
/// 左边是这件事——完成圈、就地改的标题与一句说明、待发的提示词一条一行（`PromptLine`，点哪条右边就编辑哪条；送达就用掉了，
/// 发过的话在会话里看）、子任务；
/// 右边是选中那条提示词的编辑区与操作栏（复制、去处、发给 Agent，⌘↩ 同主钮）。点开任务时右边是第一条还没交出去的提示词；
/// 一条都没有时右边请你写第一条。整页的编辑页只给散放的灵感。
struct TaskSheet: View {
    struct Request: Identifiable, Equatable {
        let id: UUID
        /// 右边编辑的那条提示词；nil 时取第一条还没交出去的。换它不换浮窗（浮窗按 `id` 认）。
        var prompt: UUID?
    }

    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @Environment(\.closePanel) private var close
    @State private var data: SheetData?

    private static let size = CGSize(width: 880, height: 600)
    private static let listWidth: CGFloat = 300

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data {
                VStack(spacing: 0) {
                    header(data)
                    Divider().overlay(palette.hair)
                    HStack(spacing: 0) {
                        list(data).frame(width: Self.listWidth)
                        Divider().overlay(palette.hair)
                        detail(data)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(palette.desk)
        .observing(services.store, id: taskID, into: $data, onError: workspace.fail) { [taskID] in try SheetData.read(taskID, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：浮窗收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        // 默认选中的那条也记下来：左边那一行垫选中色，与点过的一样
        .onChange(of: data.flatMap { selected($0)?.id }, initial: true) { _, id in
            if let id, workspace.openTask?.id == taskID, workspace.openTask?.prompt == nil { workspace.openTask?.prompt = id }
        }
    }

    /// 选中的提示词：点过的那条，否则第一条还没交出去的，再否则第一条。
    private func selected(_ data: SheetData) -> Card? {
        let prompts = data.detail.prompts
        let chosen = workspace.openTask?.prompt ?? data.detail.primaryPrompt(agents: agents)
        return prompts.first { $0.id == chosen } ?? prompts.first
    }

    private func header(_ data: SheetData) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? CaptureCopy.unfiled)
                .foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            if let parent = data.parent {
                Dot()
                Button { workspace.open(parent) } label: { Label(parent.title, systemImage: "arrow.turn.left.up").lineLimit(1) }
                    .buttonStyle(.plain)
                    .help("回到上级任务")
            }
            Spacer(minLength: 12)
            Menu("更多", systemImage: "ellipsis") { CardActions(card: data.task, more: true) }
                .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            Button("关闭", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
                .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
                .buttonStyle(PressStyle())
                .help("关闭（Esc）")
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .padding(.horizontal, 18).frame(height: 48)
    }

    private func list(_ data: SheetData) -> some View {
        let task = data.task
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 4) {
                    TaskRingButton(task: task, prompts: data.detail.prompts.count, subtasks: data.detail.progress).padding(.top, 2)
                    // 换成另一条任务时重建：标题与说明的草稿只属于那一条
                    TaskHeading(task: task).id(task.id)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "提示词").padding(.horizontal, TaskRow.inset)
                    ForEach(data.detail.prompts) { prompt in
                        PromptLine(prompt: prompt)
                    }
                    addRow("写一条提示词") {
                        let id = task.id, store = services.store
                        workspace.attempt { workspace.open(try await store.createCard(body: "", under: id)) }
                    }
                    // 发出去的提示词用掉了，原话与回答都在会话里
                    if let session = task.piSessionID {
                        Button { workspace.show(.session(session)) } label: {
                            HStack(spacing: TaskRow.columnGap) {
                                Image(systemName: "bubble.left.and.text.bubble.right").frame(width: TaskRow.ringColumn)
                                Text("发过的话在会话里看")
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(Typography.meta).foregroundStyle(palette.ink3)
                            .padding(.horizontal, TaskRow.inset).frame(minHeight: 26)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if data.parent == nil {
                    VStack(alignment: .leading, spacing: 2) {
                        SubtaskList(detail: data.detail, open: workspace.open).padding(.horizontal, TaskRow.inset)
                        NewTaskField(project: task.projectID, parent: task.id)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 16)
        }
        .scrollIndicators(.automatic)
    }

    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: TaskRow.columnGap) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: TaskRow.ringColumn)
                Text(title).font(Typography.secondary)
            }
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, TaskRow.inset)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func detail(_ data: SheetData) -> some View {
        if let prompt = selected(data) {
            PromptEditor(prompt: prompt, task: data.task).id(prompt.id)
        } else {
            VStack(spacing: 14) {
                Text("这件事要 Agent 做什么？").font(Typography.emptyTitle).foregroundStyle(palette.ink)
                Text("写一条提示词，写好就能发给 Agent").font(Typography.secondary).foregroundStyle(palette.ink3)
                Button {
                    let id = data.task.id, store = services.store
                    workspace.attempt { workspace.open(try await store.createCard(body: "", under: id)) }
                } label: {
                    Label("写一条提示词", systemImage: "square.and.pencil").primaryCapsule(palette)
                }
                .buttonStyle(PressStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 右栏：选中那条提示词的编辑区（铺满、自己滚）与下面的操作栏；上沿一行写保存状态。打开时编辑器接过键盘；
/// 换一条、关浮窗都经 `CardEditing.leave` 写下没保存的字，空白的不留下。
private struct PromptEditor: View {
    let prompt: Card
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing: CardEditing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing {
                HStack {
                    Text("提示词").font(Typography.label).foregroundStyle(palette.ink3)
                    SaveStatus(editing: editing).font(Typography.meta)
                }
                .padding(.horizontal, 24).padding(.top, 14)
                editing.field(prompt, theme: .editor(palette, horizontalInset: 20))
                EditorBar(card: prompt, task: task, editing: editing).padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            editing = CardEditing(prompt, workspace: workspace)
            await NextFrame.wait()
            editing?.handle.focus()
        }
        .onDisappear { editing?.leave() }
    }
}

/// 浮窗一次读出的东西：任务、所在项目、上级（子任务才有）与下级。
nonisolated private struct SheetData: Sendable, Equatable {
    var task: Card
    var project: Project?
    var parent: Card?
    var detail: TaskDetail
    /// 已不是一条看得见的任务（删了、归档了、改回了灵感）。
    var gone: Bool { task.deletedAt != nil || task.archivedAt != nil || !task.isTask }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> SheetData {
        guard let task = try store.card(id) else { throw CueStoreError.notFound }
        return SheetData(
            task: task, project: try task.projectID.flatMap { try store.project($0) },
            parent: try task.parentID.flatMap { try store.card($0) }, detail: try TaskDetail.read(id, from: store))
    }
}
#endif
