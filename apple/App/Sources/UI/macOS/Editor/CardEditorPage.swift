#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

nonisolated private struct EditorData: Sendable {
    var card: Card
    var project: Project?
}

/// 打开的卡：从墙上的位置连续放大成居中的纸，底部玻璃操作栏（复制、分块与编号、变量取值、发送）。
/// 纸底下的项目页保持挂载，关掉后回到原来的滚动位置。
struct CardEditorPage: View {
    let cardID: UUID
    let paperSpace: Namespace.ID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var liveText = ""
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?
    @State private var saving = false

    private static let paperWidth: CGFloat = 760
    private static let barClearance: CGFloat = 84

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.paper)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hair))
                .shadow(color: .black.opacity(palette.dark ? 0 : 0.06), radius: 12, y: 4)
                .matchedGeometryEffect(id: cardID, in: paperSpace, isSource: true)
                .frame(maxWidth: Self.paperWidth)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .ignoresSafeArea(edges: .bottom)
            if let data, let initialText {
                VStack(alignment: .leading, spacing: 10) {
                    meta(data)
                    editor(data, initialText)
                }
                .frame(maxWidth: Self.paperWidth)
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, Self.barClearance)
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
            }
        }
        .overlay(alignment: .bottom) {
            if let data {
                EditorBar(card: data.card, text: liveText, handle: handle).padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
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
        .onAppear { makeAutosave() }
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 8) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "未归档").foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            Text("·")
            Text(DateLabel.short(data.card.modifiedAt))
            Text(saving ? "保存中…" : "已自动保存")
            if data.card.isFavorite { Image(systemName: "pin.fill").help("置顶") }
            if data.project?.goalCardID == data.card.id { Label("项目目标", systemImage: "scope") }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .padding(.horizontal, 64)
    }

    private func editor(_ data: EditorData, _ text: String) -> some View {
        EditorHost(
            initialText: text,
            theme: .paper(palette),
            numbering: CueNumbering(rawValue: data.card.numbering.rawValue) ?? .none,
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
                saving = true
                defer { saving = false }
                try await store.updateCard(id) { $0.body = body }
            },
            onError: workspace.fail)
    }

    /// 分隔线上的复制/发送与 ⌘⇧C：只作用于这一块。
    private func blockAction(_ action: CueBlockAction) {
        guard let card = data?.card else { return }
        let text = CueVariables.fill(CueSegments.trim(action.text), values: card.variableValues)
        let choice: SendChoice = action.kind == .copy ? .clipboard : workspace.effectiveChoice(for: card.projectID)
        Task { await workspace.send(text, via: choice, card: card.id) }
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
                    Button("分块", systemImage: "scissors") { handle.insertSplit() }
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

    private func send(_ choice: SendChoice) {
        let body = handle.text ?? text
        let outgoing = Outgoing.text(body: body, values: card.variableValues, numbering: card.numbering)
        let id = card.id
        Task { await workspace.send(outgoing, via: choice, card: id) }
    }
}

private struct NumberingMenu: View {
    let card: Card
    @Environment(Workspace.self) private var workspace

    private static let options: [(Numbering, String)] = [(.none, "不编号"), (.decimal, "1 2 3"), (.alpha, "A B C"), (.cjk, "一 二 三")]

    var body: some View {
        Menu {
            Picker("分块编号", selection: binding) {
                ForEach(Self.options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: card.numbering == .none ? "list.bullet" : "list.number")
        }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        .help("分块编号：复制与发送时每块前加编号标题")
        .accessibilityLabel("分块编号")
        .accessibilityValue(Self.options.first { $0.0 == card.numbering }?.1 ?? "")
    }

    private var binding: Binding<Numbering> {
        Binding(get: { card.numbering }, set: { value in
            let id = card.id
            workspace.perform { try await $0.updateCard(id) { $0.numbering = value } }
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
#endif
