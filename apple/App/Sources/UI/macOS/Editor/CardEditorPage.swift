#if os(macOS)
import AppKit
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
    /// 这张卡最近一次发给谁：过渡中纸上的卡面与墙上那张一模一样（见 `CardFace`）。
    var lastTarget: String?
    /// 提示词所在的任务（挂在任务下的灵感）。
    var task: Card?

    static func read(_ id: UUID, from store: isolated CueStore) throws -> EditorData {
        guard let card = try store.card(id) else { throw CueStoreError.notFound }
        return EditorData(
            card: card, project: try card.projectID.flatMap { try store.project($0) },
            lastTarget: try store.lastSends(in: card.projectID)[card.id]?.target.shownName,
            task: try card.isTask ? nil : card.parentID.flatMap { try store.card($0) })
    }
}

/// 打开的卡：纸从墙上那张卡的边框连续放大成居中的纸页，关闭时沿原路缩回那张卡的边框。
/// 过渡中只动纸的外框（一块实色形状，不重新排字），纸上写着原卡片的标题与摘要；纸始终在最上层。
/// 任何一帧屏幕上只有一份这张卡的字：纸上的卡面与编辑器位置、字号不同，铺满（缩回前）的同一帧互换，
/// 不淡入淡出（交叉淡化是两份字叠影，先退后进中间是空白纸）；墙上原卡片在纸接过它（开始放大）的同一帧隐去，纸缩回后的同一帧回来。
/// 纸底下的项目页保持挂载，关掉后回到原来的滚动位置。
/// 纸页常驻：窗口里一直挂着这一个（`EditorLayer`），收起时只是透明、点不到、停用，编辑器与底栏不卸下；开哪张卡就把哪张卡的正文换进同一个编辑器（`EditorHost.loadKey`）、
/// 卡片相关的状态（自动保存、选区、保存状态、任务详情）整套重置（`begin`）。每次开纸页现挂编辑器与底栏要两个各约三十毫秒的长帧；常驻后开纸页只剩换正文。
/// 第一张卡开之前也在空闲时挂好（`warm`）。
struct CardEditorPage: View {
    /// 这一轮（`begin` 起）纸页对应的卡；收起后仍留着，编辑器里还是它的字，直到下一张卡换进来。
    @State private var cardID: UUID?
    /// 这一轮的标记：缩回、起飞的完成回调与准备步骤都认它，换了卡（或重开）就作废，不会把新一轮的纸收掉。
    @State private var round = UUID()
    /// 开过、还没处理完"没写东西就离开"的那张卡。
    @State private var edited: UUID?
    @State private var loadKey = 0
    /// 最近一份读到的数据：挂着的编辑器与底栏用它（本轮的数据到之前显示上一张的，是隐形的）。
    @State private var shownData: EditorData?
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
    /// 纸已接过原卡片、开始放大（见 `prepare`）。
    @State private var launched = false
    /// 缩回原卡片后纸隐去（没开过时也是隐去的）。
    @State private var paperGone = true
    @State private var pageOrigin: CGPoint = .zero
    @State private var paperFrame: CGRect = .zero
    /// 任务才有：提示词与子任务（与手机任务页同一份 `TaskDetail`）。
    @State private var taskDetail: TaskDetail?

    private static let paperWidth: CGFloat = 760
    private static let barClearance: CGFloat = 84
    private static let radius: CGFloat = 22

    private var isOpen: Bool { cardID != nil && workspace.openCard == cardID }
    /// 编辑器、底栏、任务页用的数据：本轮的到了用本轮的。
    private var shown: EditorData? { data ?? shownData }

    var body: some View {
        ZStack(alignment: .top) {
            // 纸铺开后才把墙盖住；纸本身全程不透明
            palette.desk.ignoresSafeArea().opacity(expanded ? 1 : 0)
            paperShape
            if let shown {
                let isTask = data?.card.isTask == true
                VStack(alignment: .leading, spacing: 10) {
                    meta(shown)
                    // 编辑器一直挂着（任务的纸页上是透明的）：换成别的卡不卸下它
                    ZStack(alignment: .top) {
                        editor(shown, initialText ?? "")
                            .opacity(isTask ? 0 : 1)
                            .allowsHitTesting(!isTask)
                            .accessibilityHidden(isTask)
                        if isTask, let data { taskContent(data.card) }
                    }
                }
                .frame(maxWidth: Self.paperWidth)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, Self.barClearance)
                .opacity(editorShown ? 1 : 0)
            }
        }
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .overlay(alignment: .bottom) {
            // 底栏不在纸上：一直挂着、不可见，随编辑器出现后淡入、关闭时先退
            if let shown, !shown.card.isTask {
                let visible = isOpen && editorShown && data?.card.isTask != true
                EditorBar(card: shown.card, text: liveText, handle: handle, selecting: selecting)
                    .padding(.bottom, 16)
                    .opacity(visible ? 1 : 0)
                    .disabled(!visible)
                    .accessibilityHidden(!visible)
                    .animation(.easeOut(duration: 0.12), value: visible)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pageOrigin = $0 }
        // 铺开到换成编辑器之前、缩回到纸隐去之前都在过渡
        .debugSettling(isOpen ? !editorShown : !paperGone)
        .background {
            if data?.card.isTask == true {
                Color.clear.observing(services.store, id: cardID, into: $taskDetail, onError: workspace.fail) { [cardID] in
                    guard let cardID else { throw CueStoreError.notFound }
                    return try TaskDetail.read(cardID, from: $0)
                }
            }
        }
        .observing(services.store, id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
            guard let cardID else { throw CueStoreError.notFound }
            return try EditorData.read(cardID, from: store)
        }
        // 没开着（也没在缩回）时不订阅
        .environment(\.pageActive, cardID != nil && (isOpen || !paperGone))
        .onChange(of: workspace.openCard, initial: true) { _, card in
            if let card, card == workspace.presentedCard { begin(card) } else if card == nil { collapse() }
        }
        .onChange(of: data) {
            guard let data else { return }
            shownData = data
            guard initialText == nil, data.card.id == cardID else { return }
            // 任务的纸页上没有编辑器正文
            let body = data.card.isTask ? "" : data.card.body
            initialText = body
            liveText = body
            if !data.card.isTask { loadKey += 1 }
        }
        .onChange(of: data?.card.deletedAt) { if isOpen, data?.card.deletedAt != nil { workspace.openCard = nil } }
        // 量到纸页位置、正文也读到之后才铺开：第一帧外框在原卡片上，正文按时淡入而不是读到时突然出现
        .onChange(of: paperFrame.isEmpty || initialText == nil, initial: true) { _, waiting in
            if !waiting, isOpen, !launched { prepare() }
        }
        .task(id: workspace.isLibraryReady) {
            guard workspace.isLibraryReady else { return }
            try? await Task.sleep(for: .seconds(2))
            await warm()
        }
        // 什么都没写就离开（新记的一条、新写的提示词）：不留下这条；窗口关了、纸页还没收完时也在这里收尾
        .onDisappear { if let edited { workspace.leaveEditing(edited, flush: autosave) } }
    }

    /// 开一张卡：上一张没处理完的先收尾，卡片相关的状态整套重置，编辑器等本轮的数据到了再换正文。
    private func begin(_ card: UUID) {
        if let edited { workspace.leaveEditing(edited, flush: autosave) }
        round = UUID()
        cardID = card
        edited = card
        autosave = makeAutosave(for: card, round: round)
        saveState = .idle
        selecting = false
        taskDetail = nil
        data = nil
        initialText = nil
        launched = false
        paperGone = false
        expanded = false
        editorShown = false
    }

    /// 启动后空闲时把编辑器与底栏挂好（隐形）：第一次开纸页也只剩换正文。挂的是当前项目里第一条灵感，不改任何状态、不订阅。
    private func warm() async {
        guard cardID == nil, shownData == nil else { return }
        let store = services.store
        guard let id = try? await store.cards(in: workspace.currentProject).first(where: { !$0.isTask })?.id,
              let warm = try? await EditorData.read(id, from: store), cardID == nil, shownData == nil
        else { return }
        shownData = warm
        initialText = warm.card.body
        liveText = warm.card.body
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
        guard let target = workspace.agentTarget(for: prompt.projectID) else { return workspace.openCard = prompt.id }
        let text = Outgoing.text(of: prompt), id = prompt.id
        Task { await workspace.send(text, to: target, card: id) }
    }

    /// 原卡片在本页里的边框；找不到原卡片（不在墙上）时为 nil。
    private var sourceFrame: CGRect? {
        cardID.flatMap { workspace.presence(of: $0).frame }.map { $0.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y) }
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
                .opacity(data == nil || paperGone || !launched && isOpen || source == nil && !expanded ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    /// 重活先做完再动：原卡片保持按下（`CardPresence.Phase.opening`，点下与键盘打开都一样），本轮的正文换进编辑器（数据到的那一圈），
    /// 下一帧让编辑器接过键盘（第一次要激活输入法上下文，与输入法进程同步往返）并让纸接过原卡片开始放大；
    /// 放大途中与铺满换成编辑器的每一帧，只剩动画本身与改透明度。
    private func prepare() {
        let mine = round
        Task {
            // 看一眼：准备途中已经关了、换了卡就停下（关闭由 collapse 收尾）
            await NextFrame.wait()
            guard mine == round, isOpen else { return }
            handle.focus()
            launch()
        }
    }

    /// 纸接过原卡片：同一帧原卡片隐去、纸以按下的样子出现在它的位置上，随即放大。
    private func launch() {
        guard let card = cardID else { return }
        let mine = round
        launched = true
        workspace.cover(card)
        withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) {
            expanded = true
        } completion: {
            // 铺满的同一帧换成编辑器；铺开途中已经关了、换了卡就不换
            if mine == round, isOpen { editorShown = true }
        }
    }

    /// 同一帧换回原卡片的卡面，外框缩回原卡片；缩完的同一帧纸隐去、原卡片回来，编辑器与底栏留着（隐形）。
    /// 没写东西的卡在下一帧收尾，那时屏幕上已经没有变化。
    private func collapse() {
        guard let card = cardID else { return }
        let mine = round
        editorShown = false
        withAnimation(Motion.spatial(Motion.paperClose, reduceMotion: reduceMotion)) {
            expanded = false
        } completion: {
            guard mine == round else { return }
            paperGone = true
            workspace.uncover(card)
            Task {
                await NextFrame.wait()
                guard mine == round else { return }
                if let edited {
                    workspace.leaveEditing(edited, flush: autosave)
                    self.edited = nil
                }
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
            loadKey: loadKey,
            enabled: isOpen,
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

    private func makeAutosave(for card: UUID, round: UUID) -> Autosave {
        let store = services.store
        return Autosave(
            save: { body in
                if self.round == round { saveState = .saving }
                try await store.updateCard(card) { $0.body = body }
                if self.round == round { saveState = .saved }
            },
            onError: { error in
                if self.round == round { saveState = .failed }
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
