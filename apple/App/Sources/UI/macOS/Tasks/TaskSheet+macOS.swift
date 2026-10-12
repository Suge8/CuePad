#if os(macOS)
import CueStore
import SwiftUI

/// 任务浮窗：点任务或它的提示词（项目页的任务区、任务面板、⌘K、归档）就在当前页上弹出，不换页。上面是所在项目（子任务另写上级，点它回到上级）、
/// 完成圈、就地改的标题与一句说明；下面是它的提示词——点一条就在原地展开成编辑区（`PromptEditor`），卡上直接交给 Agent——
/// 与子任务（点开换成子任务的浮窗），顶层任务末尾可直接添加子任务。整页的编辑页只给散放的灵感。
struct TaskSheet: View {
    struct Request: Identifiable, Equatable {
        let id: UUID
        /// 就地展开编辑的那条提示词。换它不换浮窗（浮窗按 `id` 认）。
        var prompt: UUID?
    }

    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @State private var data: SheetData?

    private static let width: CGFloat = 640
    private static let maxHeight: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data {
                header(data)
                ScrollView { content(data) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.desk)
        .observing(services.store, id: taskID, into: $data, onError: workspace.fail) { [taskID] in try SheetData.read(taskID, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：浮层收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
    }

    private func header(_ data: SheetData) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? CaptureCopy.unfiled)
                .foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            if let parent = data.parent {
                Dot()
                Button { workspace.open(parent) } label: {
                    Label(parent.title, systemImage: "arrow.turn.left.up").lineLimit(1)
                }
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
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 4)
    }

    private func content(_ data: SheetData) -> some View {
        let task = data.task
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 6) {
                TaskRingButton(task: task, marks: data.detail.marks).padding(.top, 3)
                // 换成另一条任务时重建：标题与说明的草稿只属于那一条
                TaskHeading(task: task).id(task.id)
            }
            PromptList(
                task: task, detail: data.detail, open: workspace.open, hand: { workspace.handOff($0) },
                write: {
                    let id = task.id, store = services.store
                    workspace.attempt { workspace.open(try await store.createCard(body: "", under: id)) }
                },
                expanded: workspace.openTask?.prompt
            ) { PromptEditor(prompt: $0, task: task).id($0.id) }
            if data.parent == nil {
                VStack(alignment: .leading, spacing: 4) {
                    SubtaskList(detail: data.detail, open: workspace.open)
                    NewTaskField(project: task.projectID, parent: task.id)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 24)
    }
}

/// 浮窗里就地展开的一条提示词：上沿写"提示词"与保存状态、右边收起；中间是定高、自己滚的编辑区；下面接编辑的操作栏
/// （复制、去处、交给 Agent，⌘↩ 同主钮）。展开时编辑器接过键盘；收起、换一条、关浮窗都经 `CardEditing.leave` 写下没保存的字。
private struct PromptEditor: View {
    let prompt: Card
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing: CardEditing?

    private static let editorHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("编辑提示词").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                if let editing { SaveStatus(editing: editing).font(TaskMetrics.caption) }
                Spacer()
                Button("收起", systemImage: "chevron.up") { workspace.openTask?.prompt = nil }
                    .labelStyle(.titleAndIcon).font(TaskMetrics.caption).foregroundStyle(palette.ink2).buttonStyle(.plain)
            }
            if let editing {
                editing.field(prompt, theme: .editor(palette, horizontalInset: 4)).frame(height: Self.editorHeight)
                EditorBar(card: prompt, task: task, editing: editing)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .background(palette.paperLit, in: .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous).strokeBorder(palette.signature.opacity(0.35)))
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
