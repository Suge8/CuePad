#if os(macOS)
import AppKit
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable {
    var card: Card
    var project: Project?
    /// 这张卡最近一次发给谁：过渡中纸上的卡面与墙上那张一模一样（见 `CardFace`）。
    var lastTarget: String?
    /// 提示词所在的任务（挂在任务下的灵感）。
    var task: Card?
}

/// 等到屏幕下一次刷新：分几帧做的事，每一步的改动落在自己那一帧里（上一步已经提交）。
/// 主队列异步不行：它有时排在同一次提交之前，几步又挤回一帧。
@MainActor
private enum NextFrame {
    static func wait() async {
        await withCheckedContinuation { continuation in
            guard let screen = NSScreen.main else { return continuation.resume() }
            let link = screen.displayLink(target: Tick(continuation), selector: #selector(Tick.fire))
            link.add(to: .main, forMode: .common)
        }
    }

    private final class Tick: NSObject {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        @objc func fire(_ link: CADisplayLink) {
            link.invalidate()
            continuation?.resume()
            continuation = nil
        }
    }
}

/// 打开的卡：纸从墙上那张卡的边框连续放大成居中的纸页，关闭时沿原路缩回那张卡的边框。
/// 过渡中只动纸的外框（一块实色形状，不重新排字），纸上写着原卡片的标题与摘要；纸始终在最上层。
/// 任何一帧屏幕上只有一份这张卡的字：纸上的卡面与编辑器位置、字号不同，铺满（缩回前）的同一帧互换，
/// 不淡入淡出（交叉淡化是两份字叠影，先退后进中间是空白纸）；墙上原卡片在纸接过它（开始放大）的同一帧隐去，纸缩回后的同一帧回来。
/// 纸底下的项目页保持挂载，关掉后回到原来的滚动位置。
struct CardEditorPage: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var liveText = ""
    /// 编辑器里有没有选中文字：有时底栏的发送只发选中的部分，并多一个"转为任务"。
    @State private var selecting = false
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?
    @State private var saveState = SaveState.idle
    /// 纸是否已铺开（外框在纸页位置）；false 时外框落在原卡片上。
    @State private var expanded = false
    /// 纸上是编辑器（true）还是原卡片的卡面（false）。
    @State private var editorShown = false
    /// 已经挂上的部分（见 `prepare`）。
    @State private var stage = Stage.paper
    /// 缩回原卡片后纸隐去，下一帧再卸下纸页。
    @State private var paperGone = false
    @State private var pageOrigin: CGPoint = .zero
    @State private var paperFrame: CGRect = .zero
    /// 任务才有：提示词与子任务（与手机任务页同一份 `TaskDetail`）。
    @State private var taskDetail: TaskDetail?

    private static let paperWidth: CGFloat = 760
    private static let barClearance: CGFloat = 84
    private static let radius: CGFloat = 22

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack(alignment: .top) {
            // 纸铺开后才把墙盖住；纸本身全程不透明
            palette.desk.ignoresSafeArea().opacity(expanded ? 1 : 0)
            paperShape
            if stage >= .editor, let data, let initialText {
                VStack(alignment: .leading, spacing: 10) {
                    meta(data)
                    if data.card.isTask { taskContent(data.card) } else { editor(data, initialText) }
                }
                .frame(maxWidth: Self.paperWidth)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, Self.barClearance)
                .opacity(editorShown ? 1 : 0)
            }
        }
        .overlay(alignment: .bottom) {
            // 底栏不在纸上：提前挂好、不可见，随编辑器出现后淡入、关闭时先退
            if stage >= .bar, let data, !data.card.isTask {
                let shown = isOpen && editorShown
                EditorBar(card: data.card, text: liveText, handle: handle, selecting: selecting)
                    .padding(.bottom, 16)
                    .opacity(shown ? 1 : 0)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
                    .animation(.easeOut(duration: 0.12), value: shown)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pageOrigin = $0 }
        .background {
            if data?.card.isTask == true {
                Color.clear.observing(services.store, TaskDetail.tables, id: cardID, into: $taskDetail, onError: workspace.fail) { [cardID] in
                    try TaskDetail.read(cardID, from: $0)
                }
            }
        }
        .observing(services.store, [.cards, .projects], id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return EditorData(
                card: card, project: try card.projectID.flatMap { try store.project($0) },
                lastTarget: try store.lastSends(in: card.projectID)[card.id]?.target.shownName,
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
        // 量到纸页位置、正文也读到之后才铺开：第一帧外框在原卡片上，正文按时淡入而不是读到时突然出现
        .onChange(of: paperFrame.isEmpty || initialText == nil, initial: true) { _, waiting in
            if !waiting, isOpen, stage == .paper { prepare() }
        }
        // 什么都没写就离开（新记的一条、新写的提示词）：不留下这条
        .onDisappear { workspace.leaveEditing(cardID, flush: autosave) }
    }

    /// 任务的纸页：完成圈与标题、一句说明，下面是提示词卡片与子任务（与手机任务页同一组件）。打开提示词或子任务是换一页。
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
                        workspace.attempt { workspace.openCard = try await workspace.createPrompt(under: id).id }
                    })
                SubtaskList(detail: taskDetail, open: { workspace.openCard = $0.id })
            }
            .padding(.horizontal, 64).padding(.vertical, 8)
        }
        .scrollIndicators(.automatic)
    }

    /// 提示词卡上的"交给 Agent"：发给本项目当前的 Agent 会话（与提示词纸页同一个），提示词关联到它；没有会话时打开它的纸页去选。
    private func hand(_ prompt: Card) {
        guard let target = workspace.agentTarget(for: prompt.projectID), !workspace.isEnded(target) else { return workspace.openCard = prompt.id }
        let text = Outgoing.text(of: prompt), id = prompt.id
        Task { await workspace.send(text, to: target, card: id) }
    }

    /// 原卡片在本页里的边框；找不到原卡片（不在墙上）时为 nil。
    private var sourceFrame: CGRect? {
        workspace.presence(of: cardID).frame.map { $0.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y) }
    }

    /// 纸此刻的边框：铺开时是纸页的位置，否则是原卡片的边框。
    private var paperRect: CGRect {
        expanded || sourceFrame == nil || reduceMotion ? paperFrame : sourceFrame!
    }

    /// 纸的外框：铺开时是纸页的位置，否则是原卡片的边框（找不到原卡片时从纸页位置略缩小淡入）。
    private var paperShape: some View {
        // 圆角与大小都从原卡片按下的样子起飞（见 `CardOpenStyle`），随铺开过渡到纸页；缩回时落回原卡片松开的样子
        let shape = RoundedRectangle(cornerRadius: expanded ? Self.radius : CardTile.radius, style: .continuous)
        let launching = isOpen && !expanded && !reduceMotion
        let source = sourceFrame
        let rect = paperRect
        return ZStack(alignment: .top) {
            // 占位：量出纸页铺开时的位置
            Color.clear
                .frame(maxWidth: Self.paperWidth, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .ignoresSafeArea(edges: .bottom)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    paperFrame = $0.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y)
                }
            shape.fill(palette.paper)
                .overlay(shape.strokeBorder(palette.hair))
                .shadow(color: .black.opacity(palette.dark ? 0 : 0.06), radius: 12, y: 4)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                // 过渡中纸上是原卡片的卡面（编辑器只在铺开后出现）：放大、缩回的每一帧纸上都有字，盖上与落回时与原卡片一模一样
                .overlay(alignment: .topLeading) {
                    if let data {
                        // 按原卡片的宽度排版、不随纸变宽重新折行：纸放大时字留在原处，只是纸边退开
                        CardFace(
                            card: data.card, lastTarget: data.lastTarget, floated: false)
                            .frame(width: (source ?? rect).width, alignment: .topLeading)
                            .opacity(editorShown ? 0 : 1)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(shape)
                .scaleEffect(launching ? Motion.pressScale : 1)
                .position(x: rect.midX, y: rect.midY)
                // 纸在开始放大时才接过原卡片（准备期间是原卡片自己按着），收起时一直在，缩回原卡片后隐去
                .opacity(data == nil || paperGone || stage < .launched && isOpen || source == nil && !expanded ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    /// 重活先做完再动：原卡片保持按下（`CardPresence.Phase.opening`，点下与键盘打开都一样），接下来几帧依次挂上编辑器、
    /// 挂上底栏（都不可见）、让编辑器接过键盘，再由纸接过原卡片开始放大。这几步各要十几毫秒，放在纸还没动的时候，每步一帧；
    /// 放大途中与铺满换成编辑器的每一帧，只剩动画本身与改透明度。
    private func prepare() {
        Task {
            // 每一步之前都看一眼：准备途中已经关了就停下（关闭由 collapse 收尾）
            await NextFrame.wait()
            guard isOpen else { return }
            stage = .editor
            await NextFrame.wait()
            guard isOpen else { return }
            stage = .bar
            // 编辑器接过键盘要激活输入法上下文（与输入法进程同步往返），也放在动之前
            await NextFrame.wait()
            guard isOpen else { return }
            handle.focus()
            await NextFrame.wait()
            if isOpen { launch() }
        }
    }

    /// 纸接过原卡片：同一帧原卡片隐去、纸以按下的样子出现在它的位置上，随即放大。
    private func launch() {
        stage = .launched
        workspace.cover(cardID)
        withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) {
            expanded = true
        } completion: {
            // 铺满的同一帧换成编辑器；铺开途中已经关了就不换
            if isOpen { editorShown = true }
        }
    }

    /// 同一帧换回原卡片的卡面，外框缩回原卡片；缩完的同一帧纸隐去、原卡片回来，
    /// 卸下纸页（编辑器、底栏，几十毫秒）放到下一帧，那时屏幕上已经没有变化。
    private func collapse() {
        editorShown = false
        withAnimation(Motion.spatial(Motion.paperClose, reduceMotion: reduceMotion)) {
            expanded = false
        } completion: {
            paperGone = true
            workspace.uncover(cardID)
            Task {
                await NextFrame.wait()
                workspace.finishClosingCard()
            }
        }
    }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 8) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "未分类").foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
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
            if data.card.isTask { Label("任务", systemImage: "checklist") }
            Spacer(minLength: 0)
            Menu("更多", systemImage: "ellipsis") {
                CardActions(card: data.card, more: true)
            }
            .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .padding(.horizontal, 64)
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
            theme: .paper(palette),
            handle: handle,
            onChange: { next in
                liveText = next
                autosave?.changed(next)
            },
            onSelectionChange: { selecting = $0 },
            selectionActions: selectionActions(data.card),
            onError: workspace.fail)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [palette.paper.opacity(0), palette.paper], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .padding(.horizontal, 1) // 让出纸边描边
                .allowsHitTesting(false)
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

    /// 右键菜单里的选区动作：转为任务；提示词另有"发送选中部分"（发给本项目当前的 Agent 会话）。
    private func selectionActions(_ card: Card) -> [CueSelectionAction] {
        let tasks = CueSelectionAction(title: "转为任务", systemImage: "checklist") { stored in
            workspace.convertToTasks(stored, in: card.projectID)
        }
        guard CardMenu.handsToAgent(card) else { return [tasks] }
        let send = CueSelectionAction(title: "发送选中部分", systemImage: "paperplane") { stored in
            guard let target = workspace.agentTarget(for: card.projectID) else { return }
            let text = Outgoing.text(body: stored, values: card.variableValues)
            Task { await workspace.send(text, to: target, card: card.id) }
        }
        return [send, tasks]
    }
}

/// 纸页挂到了哪一步：先只有（不可见的）纸，再挂编辑器、挂底栏，最后纸接过原卡片开始放大。
private enum Stage: Int, Comparable {
    case paper, editor, bar, launched

    static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
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

/// 分割线按钮的图形"— · —"：系统没有贴切的符号，方框加一横的那个读不出是分割线。
private struct DividerGlyph: View {
    private static let segment: CGFloat = 7, line: CGFloat = 2
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2.5) {
            Capsule().frame(width: Self.segment, height: Self.line)
            Circle().frame(width: 3.5, height: 3.5)
            Capsule().frame(width: Self.segment, height: Self.line)
        }
        .foregroundStyle(palette.ink)
        .frame(height: 16)
    }
}

/// 编辑页底部的玻璃操作栏：复制全文、插分割线；主动作在右边——灵感是"挂到任务"，提示词是发给 Agent（都是 ⌘↩）。
/// 选中文字时发送只发选中的部分，并多一个"转为任务"。
private struct EditorBar: View {
    let card: Card
    let text: String
    let handle: EditorHandle
    let selecting: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let names = CueVariables.names(in: text)
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 16) {
                    Button("复制全文", systemImage: "doc.on.doc") { workspace.copy(outgoing(whole: true)) }
                        .help("复制全文（变量已填）")
                    Button { handle.insertDivider() } label: { Label { Text("插入分割线") } icon: { DividerGlyph() } }
                        .help("在光标处插入一条分割线")
                    if selecting {
                        Button("转为任务", systemImage: "checklist") {
                            if let selection = handle.selection { workspace.convertToTasks(selection, in: card.projectID) }
                        }
                        .help("选中的每一行成为一个任务")
                        .transition(.opacity)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(PressStyle(scale: 0.88))
                .font(.system(size: 14))
                .padding(.horizontal, 16).frame(height: 44)
                .glass(in: .capsule, interactive: true)
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                if selecting {
                    Text("选中部分").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3)
                        .transition(.opacity)
                }
                if CardMenu.handsToAgent(card) {
                    let start = workspace.newSessionHandOff(for: card)
                    SendControl(project: card.projectID, newSession: start.map { start in { start(outgoing(whole: false)) } }) { send(to: $0) }
                } else {
                    attach
                }
            }
            .animation(Motion.quick, value: selecting)
        }
    }

    /// 灵感的主动作：挂到任务（弹出选任务的面板），⌘↩。
    private var attach: some View {
        Button { workspace.attaching = card } label: {
            Label(CardMenu.Item.attachToTask.title, systemImage: CardMenu.Item.attachToTask.symbol)
                .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onSignature)
                .padding(.horizontal, 16).frame(height: 44)
                .background(palette.signatureFill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .help("挂到一个任务下，成为它的提示词（⌘↩）")
    }

    /// 发给 Agent：选中了就只发选中的部分。
    private func send(to target: AgentTarget) {
        let outgoing = outgoing(whole: false), id = card.id
        Task { await workspace.send(outgoing, to: target, card: id) }
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
