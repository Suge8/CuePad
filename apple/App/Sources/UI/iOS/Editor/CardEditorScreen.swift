#if os(iOS)
import CueEditor
import CueStore
import CueText
import PhotosUI
import SwiftUI

nonisolated private struct EditorData: Sendable {
    var card: Card
    var project: Project?
}

/// 打开的卡：一整张纸页。键盘上方是编辑器自带的工具栏（分块、插图、变量取值）；
/// 导航栏右侧是分享与"更多"（复制、编号、置顶、设为目标、移到回收站）。
struct CardEditorScreen: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var liveText = ""
    @State private var handle = IOSEditorHandle()
    @State private var autosave: Autosave?
    @State private var saving = false
    @State private var pickingImage = false
    @State private var pickedImage: PhotosPickerItem?
    @State private var editingVariables = false
    @State private var flushToken: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data {
                meta(data).padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 6)
            }
            if let data, let initialText {
                IOSEditorHost(
                    initialText: initialText,
                    theme: .paper(palette, horizontalInset: 20),
                    numbering: CueNumbering(rawValue: data.card.numbering.rawValue) ?? .none,
                    handle: handle,
                    onChange: { next in
                        liveText = next
                        autosave?.changed(next)
                    },
                    onInsertImage: { pickingImage = true },
                    onVariables: { editingVariables = true },
                    onBlockAction: blockAction,
                    onError: workspace.fail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .photosPicker(isPresented: $pickingImage, selection: $pickedImage, matching: .images)
        .onChange(of: pickedImage) { insertPicked() }
        .sheet(isPresented: $editingVariables) {
            if let card = data?.card { VariablesSheet(card: card, names: CueVariables.names(in: liveText)) }
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
        .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { dismiss() } }
        .onAppear(perform: makeAutosave)
        .onDisappear {
            if let autosave { Task { await autosave.flush() } }
            if let flushToken { services.removeBackgroundFlush(flushToken) }
        }
    }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "未归档").foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            Text("·")
            Text(DateLabel.short(data.card.modifiedAt))
            Text(saving ? "保存中…" : "已自动保存")
            if data.card.isFavorite { Image(systemName: "pin.fill").accessibilityLabel("置顶") }
        }
        .font(.caption)
        .foregroundStyle(palette.ink3)
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let card = data?.card {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: outgoing(card)) { Label("分享", systemImage: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("复制整张", systemImage: "doc.on.doc") { copy(card) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    NumberingPicker(card: card)
                    Divider()
                    CardActions(card: card, isGoal: data?.project?.goalCardID == card.id)
                }
            }
        }
    }

    /// 当前编辑中的正文（未保存的也算），变量已填、编号已排。
    private func outgoing(_ card: Card) -> String {
        Outgoing.text(body: handle.text ?? liveText, values: card.variableValues, numbering: card.numbering)
    }

    private func copy(_ card: Card) {
        let text = outgoing(card), id = card.id
        workspace.attempt {
            try await services.send(text, to: .clipboard, card: id)
            workspace.say("已复制")
        }
    }

    private func blockAction(_ action: CueBlockAction) {
        guard let card = data?.card else { return }
        let text = CueVariables.fill(CueSegments.trim(action.text), values: card.variableValues), id = card.id
        workspace.attempt {
            try await services.send(text, to: .clipboard, card: id)
            workspace.say("已复制这一块")
        }
    }

    private func insertPicked() {
        guard let item = pickedImage else { return }
        pickedImage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                handle.insertImage(data)
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func makeAutosave() {
        guard autosave == nil else { return }
        let store = services.store, id = cardID
        let autosave = Autosave(
            save: { body in
                saving = true
                defer { saving = false }
                try await store.updateCard(id) { $0.body = body }
            },
            onError: workspace.fail)
        self.autosave = autosave
        // 进入后台时由壳层等它落盘：之后 App 可能被系统结束，离开页面的 onDisappear 不会再来
        flushToken = services.addBackgroundFlush { await autosave.flush() }
    }
}

/// 分块编号：复制、分享时每块前加编号标题。
private struct NumberingPicker: View {
    let card: Card
    @Environment(Workspace.self) private var workspace

    private static let options: [(Numbering, String)] = [(.none, "不编号"), (.decimal, "1 2 3"), (.alpha, "A B C"), (.cjk, "一 二 三")]

    var body: some View {
        Picker(selection: Binding(get: { card.numbering }, set: { value in
            let id = card.id
            workspace.perform { try await $0.updateCard(id) { $0.numbering = value } }
        })) {
            ForEach(Self.options, id: \.0) { Text($0.1).tag($0.0) }
        } label: {
            Label("分块编号", systemImage: "list.number")
        }
        .pickerStyle(.menu)
    }
}

/// 变量取值：逐个填写，↩ 提交并关闭；取值存在卡片上。
private struct VariablesSheet: View {
    let card: Card
    let names: [String]
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if names.isEmpty {
                    Text("正文里还没有变量。用 {{名称}} 写一个，发送与复制时会换成这里的取值。").foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    LabeledContent("{{\(name)}}") {
                        TextField("取值", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .onSubmit(saveAndClose)
            .navigationTitle("变量取值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: saveAndClose) }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { values = card.variableValues }
    }

    private func saveAndClose() {
        let id = card.id, values = values
        if values != card.variableValues {
            workspace.perform { try await $0.updateCard(id) { $0.variableValues = values } }
        }
        dismiss()
    }
}
#endif
