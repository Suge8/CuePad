#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable {
    var card: Card
    var project: Project?
}

/// 打开的卡：纸从墙上那张卡的边框连续放大成居中的纸页，关闭时沿原路缩回那张卡的边框。
/// 过渡中只动纸的外框（一块实色形状，不重新排字），正文在纸放大后淡入、缩回前先淡出；纸始终在最上层。
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
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?
    @State private var saveState = SaveState.idle
    /// 纸是否已铺开（外框在纸页位置）；false 时外框落在原卡片上。
    @State private var expanded = false
    @State private var contentShown = false
    /// 缩回的最后一段纸淡出，露出底下已经复原的原卡片（两者同一边框，看起来是纸变回了卡）。
    @State private var paperFaded = false
    @State private var pageOrigin: CGPoint = .zero
    @State private var paperFrame: CGRect = .zero

    private static let paperWidth: CGFloat = 760
    private static let barClearance: CGFloat = 84
    private static let radius: CGFloat = 22

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack(alignment: .top) {
            // 纸铺开后才把墙盖住；纸本身全程不透明
            palette.desk.ignoresSafeArea().opacity(expanded ? 1 : 0)
            paperShape
            if let data, let initialText {
                VStack(alignment: .leading, spacing: 10) {
                    meta(data)
                    editor(data, initialText)
                }
                .frame(maxWidth: Self.paperWidth)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, Self.barClearance)
                .opacity(contentShown ? 1 : 0)
            }
        }
        .overlay(alignment: .bottom) {
            if let data, isOpen, contentShown {
                // 跟正文同一个事务进出：铺开后随正文淡入，关闭时随正文先退
                EditorBar(card: data.card, text: liveText, handle: handle).padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pageOrigin = $0 }
        .observing(services.store, [.cards, .projects], id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return EditorData(card: card, project: try card.projectID.flatMap { try store.project($0) })
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
            if !waiting, isOpen, !expanded { expand() }
        }
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    /// 原卡片在本页里的边框；找不到原卡片（不在墙上）时为 nil。
    private var sourceFrame: CGRect? {
        workspace.cardFrames[cardID].map { $0.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y) }
    }

    /// 纸此刻的边框：铺开时是纸页的位置，否则是原卡片的边框。
    private var paperRect: CGRect {
        expanded || sourceFrame == nil || reduceMotion ? paperFrame : sourceFrame!
    }

    /// 纸的外框：铺开时是纸页的位置，否则是原卡片的边框（找不到原卡片时从纸页位置略缩小淡入）。
    private var paperShape: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
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
                // 过渡中纸上写着这张卡的标题与摘要（编辑器只在铺开后出现）：放大、缩回的每一帧纸上都有字
                .overlay(alignment: .topLeading) {
                    if let card = data?.card {
                        // 按原卡片的宽度排版、不随纸变宽重新折行：纸放大时字留在原处，只是纸边退开
                        PaperGlimpse(text: CardText(card.body))
                            .frame(width: (source ?? rect).width, alignment: .topLeading)
                            .opacity(contentShown ? 0 : 1)
                    }
                }
                .clipShape(shape)
                .position(x: rect.midX, y: rect.midY)
                .opacity(source == nil && !expanded || paperFaded ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    private func expand() {
        withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) { expanded = true }
        // 纸快铺满时编辑器淡入、纸上的摘要淡出，两者交叉
        withAnimation(.easeOut(duration: 0.12).delay(reduceMotion ? 0 : 0.18)) { contentShown = true }
    }

    /// 正文先淡出，外框缩回原卡片，最后一段纸淡出露出原卡片；缩完卸下纸页。
    private func collapse() {
        // 正文在铺开的纸上淡完，纸才开始缩：不让字露到纸外
        let fade = reduceMotion ? 0 : 0.06
        withAnimation(.easeOut(duration: fade)) { contentShown = false }
        withAnimation(.easeIn(duration: 0.08).delay(fade + Motion.paperCloseDuration - 0.08)) { paperFaded = true }
        withAnimation(Motion.spatial(Motion.paperClose, reduceMotion: reduceMotion).delay(fade)) {
            expanded = false
        } completion: {
            workspace.finishClosingCard()
        }
    }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 8) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "未归档").foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            Text("·")
            Text(DateLabel.short(data.card.modifiedAt))
            if let status = saveState.text {
                Text(status).foregroundStyle(saveState == .failed ? palette.failure : palette.ink3)
                    .transition(.opacity)
            }
            if data.card.isPinned { Image(systemName: "pin.fill").help("置顶") }
            if data.project?.goalCardID == data.card.id { Label("项目目标", systemImage: "scope") }
        }
        .font(.system(size: 12))
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
            numbering: data.card.numbering.known ?? .none,
            handle: handle,
            onChange: { next in
                liveText = next
                autosave?.changed(next)
            },
            onBlockAction: blockAction,
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

    /// 分隔线上的复制/发送与 ⌘⇧C：只作用于这一块。
    private func blockAction(_ action: CueBlockAction) {
        guard let card = data?.card else { return }
        let text = CueVariables.fill(CueSegments.trim(action.text), values: card.variableValues)
        let choice: AppServices.Destination = action.kind == .copy ? .clipboard : workspace.effectiveChoice(for: card.projectID)
        Task { await workspace.send(text, via: choice, card: card.id) }
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

/// 编辑页底部的玻璃操作栏。
private struct EditorBar: View {
    let card: Card
    let text: String
    let handle: EditorHandle
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let names = CueVariables.names(in: text)
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 16) {
                    Button("复制整张", systemImage: "doc.on.doc") { send(.clipboard) }
                        .help("复制整张卡（变量已填、编号已排）")
                    Button("分块", systemImage: "rectangle.split.1x2") { handle.insertSplit() }
                        .help("在光标处分块（⇧↩）")
                    NumberingMenu(card: card)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(PressStyle(scale: 0.88))
                .font(.system(size: 14))
                .padding(.horizontal, 16).frame(height: 44)
                .glass(in: .capsule, interactive: true)
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                SendControl(project: card.projectID) { send($0) }
            }
        }
    }

    private func send(_ choice: AppServices.Destination) {
        let body = handle.text ?? text
        let outgoing = Outgoing.text(body: body, values: card.variableValues, numbering: card.numbering)
        let id = card.id
        Task { await workspace.send(outgoing, via: choice, card: id) }
    }
}

private struct NumberingMenu: View {
    let card: Card
    @Environment(Workspace.self) private var workspace

    private static let options: [(CueNumbering, String)] = [(.none, "不编号"), (.decimal, "1 2 3"), (.alpha, "A B C"), (.cjk, "一 二 三")]

    var body: some View {
        Menu {
            Picker("分块编号", selection: binding) {
                ForEach(Self.options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: card.numbering == .known(.none) ? "list.bullet" : "list.number")
        }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        .help("分块编号：复制与发送时每块前加编号标题")
        .accessibilityLabel("分块编号")
        .accessibilityValue(Self.options.first { $0.0 == card.numbering.known }?.1 ?? "")
    }

    private var binding: Binding<CueNumbering> {
        Binding(get: { card.numbering.known ?? .none }, set: { value in
            let id = card.id
            workspace.perform { try await $0.updateCard(id) { $0.numbering = .known(value) } }
        })
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
            .font(.system(size: 13, weight: .medium))
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


/// 纸放大、缩回途中纸上的内容：与卡片墙上那张卡同样的排版（首图、标题、摘要），落回卡片时两者重合。
private struct PaperGlimpse: View {
    let text: CardText
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-8).padding(.bottom, 6)
            }
            Text(text.title.isEmpty ? "空白卡片" : text.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                .lineLimit(2)
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? 4 : 2)
            }
        }
        .padding(14)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
#endif
