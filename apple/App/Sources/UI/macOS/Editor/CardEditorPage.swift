#if os(macOS)
import AppKit
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
    /// 提示词所在的任务（挂在任务下的灵感）。
    var task: Card?
}

/// 打开的卡：编辑页铺满内容区、与页面同底色（纸感留在墙上的卡片与底色上，这里不再画纸）；字限在 `textWidth` 一列里居中，
/// 编辑区本身铺满，两侧空白处也能滚。打开、收起都是原地淡入淡出，不动几何：前台每帧几何变化会让 AppKit 重算整窗的鼠标跟踪区。
/// 重活先在看不见时做完——挂上编辑器与底栏、让编辑器接过键盘，各占一帧——再淡入；这几帧里墙上那张卡保持按下（`CardPresence.opening`）。
/// 编辑页底下的项目页保持挂载，关掉后回到原来的滚动位置。
struct CardEditorPage: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var liveText = ""
    /// 编辑器里有没有选中文字：有时底栏的"交给 Agent"只交出选中的部分。
    @State private var selecting = false
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?
    @State private var saveState = SaveState.idle
    /// 编辑器与底栏已挂上（不可见，见 `prepare`）。
    @State private var mounted = false
    /// 编辑页看得见（淡入、淡出的终点）。
    @State private var shown = false
    /// 淡入走完了。
    @State private var settled = false
    /// 收起的淡出走完了（之后才卸下）。
    @State private var gone = false
    /// 任务才有：提示词与子任务（与手机任务页同一份 `TaskDetail`）。
    @State private var taskDetail: TaskDetail?

    /// 一行字最宽：苹方 15.5pt 约 44 个字，再宽读到行尾回头找下一行就费劲。
    fileprivate static let textWidth: CGFloat = 680
    /// 字离编辑区左右边的最小距离（窗口窄时）。
    fileprivate static let inset: CGFloat = 24
    private static let barClearance: CGFloat = 84
    /// 编辑区下沿淡出的那一段（内容自己的透明度，不往上画颜色）。
    private static let bottomFade: CGFloat = 28

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack(alignment: .top) {
            if mounted, let data, let initialText {
                VStack(spacing: 10) {
                    meta(data)
                    if data.card.isTask { taskContent(data.card) } else { editor(data, initialText) }
                }
                .padding(.top, Spacing.pageTop)
                .padding(.bottom, Self.barClearance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            // 底栏挂在页面之上、与编辑器同时挂好，随编辑页一起淡入淡出
            if mounted, let data, !data.card.isTask {
                EditorBar(card: data.card, task: data.task, text: liveText, handle: handle, selecting: selecting)
                    .padding(.bottom, 16)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
            }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .debugSettling(isOpen ? !settled : !gone)
        .background {
            if data?.card.isTask == true {
                Color.clear.observing(services.store, id: cardID, into: $taskDetail, onError: workspace.fail) { [cardID] in
                    try TaskDetail.read(cardID, from: $0)
                }
            }
        }
        .observing(services.store, id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return EditorData(
                card: card, project: try card.projectID.flatMap { try store.project($0) },
                task: try card.isTask ? nil : card.parentID.flatMap { try store.card($0) })
        }
        .onChange(of: data?.card.id, initial: true) {
            guard initialText == nil, let card = data?.card else { return }
            initialText = card.body
            liveText = card.body
        }
        .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { workspace.openCard = nil } }
        .onChange(of: isOpen) { if !isOpen { collapse() } }
        .onAppear(perform: makeAutosave)
        // 正文读到之后才开始准备
        .onChange(of: initialText == nil, initial: true) { _, waiting in
            if !waiting, isOpen, !mounted { prepare() }
        }
        // 什么都没写就离开（新记的一条、新写的提示词）：不留下这条
        .onDisappear { workspace.leaveEditing(cardID, flush: autosave) }
    }

    /// 任务的编辑页：完成圈与标题、一句说明，下面是提示词卡片与子任务（与手机任务页同一组件）。打开提示词或子任务是换一页。
    private func taskContent(_ task: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 6) {
                    TaskRingButton(task: task, marks: taskDetail?.marks).padding(.top, 3)
                    TaskHeading(task: task)
                }
                PromptList(
                    task: task, detail: taskDetail, open: { workspace.openCard = $0.id }, hand: hand,
                    write: {
                        let id = task.id
                        workspace.attempt { workspace.openCard = try await workspace.services.store.createCard(body: "", under: id).id }
                    })
                SubtaskList(detail: taskDetail, open: { workspace.openCard = $0.id })
            }
            .column()
            .padding(.vertical, 8)
        }
        .scrollIndicators(.automatic)
    }

    /// 提示词卡上的"交给 Agent"：与提示词编辑页同一个去处规则。
    private func hand(_ prompt: Card) { workspace.handOff(prompt) }

    /// 看不见时先把重活做完，每步一帧：挂上编辑器与底栏（一帧：分成两帧只是多一次掉帧）、让编辑器接过键盘
    /// （要激活输入法上下文，与输入法进程同步往返），最后放开墙上那张卡、淡入。淡入的每一帧只剩改透明度。
    private func prepare() {
        Task {
            // 每一步之前都看一眼：准备途中已经关了就停下（关闭由 collapse 收尾）
            await NextFrame.wait()
            guard isOpen else { return }
            mounted = true
            await NextFrame.wait()
            guard isOpen else { return }
            handle.focus()
            await NextFrame.wait()
            guard isOpen else { return }
            workspace.presses.opened(cardID)
            withAnimation(Motion.quick) { shown = true } completion: { settled = true }
        }
    }

    /// 原地淡出，淡完卸下。
    private func collapse() {
        withAnimation(Motion.quick) {
            shown = false
        } completion: {
            gone = true
            workspace.finishClosingCard()
        }
    }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 8) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? CaptureCopy.unfiled).foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            if let task = data.task {
                Dot()
                Label(task.title, systemImage: "checklist").lineLimit(1).help("这条任务的提示词")
            }
            Dot()
            Text(DateLabel.short(data.card.modifiedAt))
            if let status = saveState.text {
                Text(status).foregroundStyle(saveState == .failed ? palette.failure : palette.ink3)
                    .transition(.opacity)
            }
            if data.card.isPinned { Label("资料", systemImage: "books.vertical") }
            Spacer(minLength: 0)
            Menu("更多", systemImage: "ellipsis") {
                CardActions(card: data.card, more: true)
            }
            .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .column()
        .animation(Motion.quick, value: saveState)
        // "已保存"只亮一会儿；状态再变（又在保存、出错）时这次计时作废
        .task(id: saveState) {
            guard saveState == .saved else { return }
            try? await Task.sleep(for: SaveState.savedDisplay)
            if !Task.isCancelled { saveState = .idle }
        }
    }

    private func editor(_ data: EditorData, _ text: String) -> some View {
        EditorHost(
            initialText: text,
            theme: .editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth),
            handle: handle,
            onChange: { next in
                liveText = next
                autosave?.changed(next)
            },
            onSelectionChange: { selecting = $0 },
            selectionActions: selectionActions(data.card),
            onError: workspace.fail)
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.bottomFade)
            }
        }
    }

    private func makeAutosave() {
        guard autosave == nil else { return }
        let store = services.store, id = cardID
        autosave = Autosave(
            save: { body in
                saveState = .saving
                try await store.updateCard(id) { $0.body = body }
                saveState = .saved
            },
            onError: { error in
                saveState = .failed
                workspace.fail(error)
            })
    }

    /// 右键菜单里的选区动作：转为任务；提示词另有"交给 Agent"（只交出选中的部分）。
    private func selectionActions(_ card: Card) -> [CueSelectionAction] {
        let tasks = CueSelectionAction(title: "转为任务", systemImage: "checklist") { stored in
            workspace.convertToTasks(stored, in: card.projectID)
        }
        guard CardMenu.handsToAgent(card) else { return [tasks] }
        let send = CueSelectionAction(title: "交给 Agent", systemImage: "paperplane") { stored in
            workspace.handOff(card, text: Outgoing.text(body: stored, values: card.variableValues))
        }
        return [send, tasks]
    }
}

private extension View {
    /// 编辑页里与正文同一列：最宽 `textWidth`、居中，窗口窄时离边至少 `inset`（编辑器自己按同样的数居中，见 `CueEditorTheme.maxTextWidth`）。
    func column() -> some View {
        frame(maxWidth: CardEditorPage.textWidth, alignment: .leading)
            .padding(.horizontal, CardEditorPage.inset)
            .frame(maxWidth: .infinity)
    }
}

/// 保存状态：平时不显示；保存中显示，保存完显示"已保存"一会儿，失败一直显示直到下次保存成功。
private enum SaveState: Equatable {
    case idle, saving, saved, failed

    static let savedDisplay: Duration = .seconds(1.5)

    var text: String? {
        switch self {
        case .idle: nil
        case .saving: "保存中…"
        case .saved: "已保存"
        case .failed: "没能保存"
        }
    }
}

/// 编辑页底部的操作栏：左边复制全文（变量已填）与变量；右边是主动作——灵感是"挂到任务"，提示词是去处加"交给 Agent"（都是 ⌘↩）。
/// 选中文字时"交给 Agent"只交出选中的部分，栏上写一句"选中部分"。分割线与转为任务在编辑器的右键菜单里。
private struct EditorBar: View {
    let card: Card
    let task: Card?
    let text: String
    let handle: EditorHandle
    let selecting: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let names = CueVariables.names(in: text)
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { workspace.copy(outgoing(whole: true)) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(Typography.secondary.weight(.medium))
                        .padding(.horizontal, 16).frame(height: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .glass(in: .capsule, interactive: true)
                .help("复制全文（变量已填）")
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                Spacer(minLength: 0)
                if selecting {
                    Text("选中部分").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3)
                        .transition(.opacity)
                }
                if CardMenu.handsToAgent(card) {
                    SendControl(prompt: card, task: task) { outgoing(whole: false) }
                } else {
                    attach
                }
            }
            .animation(Motion.quick, value: selecting)
        }
        .column()
    }

    /// 灵感的主动作：挂到任务（弹出选任务的面板），⌘↩。
    private var attach: some View {
        Button { workspace.attaching = card } label: {
            Label(CardMenu.Item.attachToTask.title, systemImage: CardMenu.Item.attachToTask.symbol).primaryCapsule(palette)
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .help("挂到一个任务下，成为它的提示词（⌘↩）")
    }

    private func outgoing(whole: Bool) -> String {
        Outgoing.text(body: (whole ? nil : handle.selection) ?? handle.text ?? text, values: card.variableValues)
    }
}

/// 变量取值：显示第一个变量与其值，点开逐个填写；取值存在卡片上。
private struct VariablesChip: View {
    let card: Card
    let names: [String]
    @Environment(\.palette) private var palette
    @State private var editing = false

    var body: some View {
        Button { editing.toggle() } label: {
            HStack(spacing: 6) {
                Text("{{\(names[0])}}").foregroundStyle(palette.variable)
                Text(card.variableValues[names[0]].flatMap { $0.isEmpty ? nil : $0 } ?? "未填")
                    .foregroundStyle(card.variableValues[names[0]]?.isEmpty == false ? .primary : .secondary)
                    .lineLimit(1)
                if names.count > 1 { Text("+\(names.count - 1)").foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(Typography.secondary.weight(.medium))
            .padding(.horizontal, 14).frame(height: 44)
            .frame(maxWidth: 260)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .glass(in: .capsule, interactive: true)
        .popover(isPresented: $editing, arrowEdge: .top) { VariablesForm(card: card, names: names) { editing = false } }
        .help("变量取值")
        .accessibilityLabel("变量取值，共 \(names.count) 个")
    }
}

private struct VariablesForm: View {
    let card: Card
    let names: [String]
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @State private var values: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(names, id: \.self) { name in
                TextField("{{\(name)}}", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .onAppear { values = card.variableValues }
        .onDisappear(perform: save)
        .onSubmit(close) // ↩ 提交并关闭（关闭时保存），与 ⌘K 一致
    }

    private func save() {
        let id = card.id, values = values
        guard values != card.variableValues else { return }
        workspace.perform { try await $0.updateCard(id) { $0.variableValues = values } }
    }
}

#endif
