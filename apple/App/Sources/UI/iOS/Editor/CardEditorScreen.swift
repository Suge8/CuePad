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

/// 打开的卡：一整张纸页（宽 iPad 上是居中的纸，两侧露出桌面）。键盘上方是工具栏（分割线、插图、变量取值、发送；选中文字时发送只发选中的部分）；
/// 导航栏右侧是复制、发到 Mac 与"更多"（分享、置顶、设为目标、移动、移到回收站）。
struct CardEditorScreen: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var liveText = ""
    @State private var handle = IOSEditorHandle()
    @State private var autosave: Autosave?
    @State private var pickingImage = false
    @State private var pickedImage: PhotosPickerItem?
    @State private var editingVariables = false
    @State private var flushToken: UUID?

    private static let pageWidth: CGFloat = 760

    var body: some View {
        page
            .frame(maxWidth: wide ? Self.pageWidth : .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper, in: .rect(cornerRadius: wide ? 22 : 0, style: .continuous))
            .overlay {
                if wide { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hair).allowsHitTesting(false) }
            }
            .padding(wide ? EdgeInsets(top: 8, leading: 24, bottom: 0, trailing: 24) : EdgeInsets())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .ownsBottomEdge()
            .toolbar { toolbar }
            .photosPicker(isPresented: $pickingImage, selection: $pickedImage, matching: .images)
            .onChange(of: pickedImage) { insertPicked() }
            .sheet(isPresented: $editingVariables) {
                if let card = data?.card { VariablesSheet(card: card, names: CueVariables.names(in: handle.text ?? liveText)) }
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

    private var wide: Bool { sizeClass == .regular }

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data {
                meta(data).padding(.horizontal, inset).padding(.top, wide ? 20 : 4).padding(.bottom, 6)
            }
            if let data, let initialText {
                IOSEditorHost(
                    initialText: initialText,
                    theme: .paper(palette, horizontalInset: inset),
                    handle: handle,
                    onChange: { next in
                        liveText = next
                        autosave?.changed(next)
                    },
                    onInsertImage: { pickingImage = true },
                    onVariables: { editingVariables = true },
                    onSend: sendToMac,
                    selectionActions: selectionActions(data.card),
                    onError: workspace.fail)
            }
        }
    }

    private var inset: CGFloat { wide ? 44 : 20 }

    private func meta(_ data: EditorData) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "未归档").foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            Text("·")
            Text(DateLabel.short(data.card.modifiedAt))
            if data.project?.goalCardID == data.card.id { Image(systemName: "scope").accessibilityLabel("项目目标") }
            if data.card.isPinned { Image(systemName: "pin.fill").accessibilityLabel("置顶") }
        }
        .font(.caption)
        .foregroundStyle(palette.ink3)
        .accessibilityElement(children: .combine)
    }

    /// 按钮从第一帧就在（卡片还没读到时禁用），随放大过渡一起出现，不在过渡结束后才弹出来。
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let card = data?.card
        ToolbarItemGroup(placement: .primaryAction) {
            Button("复制", systemImage: "doc.on.doc") { if let card { copy(card) } }
                .disabled(card == nil)
            Button("发到 Mac", systemImage: "paperplane", action: sendToMac)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(card == nil)
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu("更多", systemImage: "ellipsis") {
                if let card {
                    ShareLink(item: outgoing(card)) { Label("分享", systemImage: "square.and.arrow.up") }
                    Divider()
                    CardActions(card: card, inEditor: true)
                }
            }
            .disabled(card == nil)
        }
    }

    /// 发到 Mac：选中了文字就只发选中的部分。
    private func sendToMac() {
        guard let card = data?.card else { return }
        let body = handle.selection.map { Outgoing.text(body: $0, values: card.variableValues) } ?? outgoing(card)
        navigation.outbox = Navigation.Outbox(content: body, card: card.id, project: card.projectID)
    }

    /// 编辑菜单里的选区动作。
    private func selectionActions(_ card: Card) -> [CueSelectionAction] {
        [
            CueSelectionAction(title: "发到 Mac", systemImage: "paperplane") { stored in
                let body = Outgoing.text(body: stored, values: card.variableValues)
                navigation.outbox = Navigation.Outbox(content: body, card: card.id, project: card.projectID)
            },
            CueSelectionAction(title: "转为任务", systemImage: "checklist") { stored in
                workspace.convertToTasks(stored, in: card.projectID)
            },
        ]
    }

    /// 当前编辑中的整张正文（未保存的也算），变量已填。
    private func outgoing(_ card: Card) -> String {
        Outgoing.text(body: handle.text ?? liveText, values: card.variableValues)
    }

    private func copy(_ card: Card) {
        let text = outgoing(card), id = card.id
        workspace.attempt {
            try await services.send(text, to: .clipboard, card: id)
            workspace.say("已复制")
        }
    }

    private func insertPicked() {
        guard let item = pickedImage else { return }
        pickedImage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                handle.insertImage(PickedImage(data: data).data)
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func makeAutosave() {
        guard autosave == nil else { return }
        let store = services.store, id = cardID
        let autosave = Autosave(
            save: { body in try await store.updateCard(id) { $0.body = body } },
            onError: workspace.fail)
        self.autosave = autosave
        // 进入后台时由壳层等它落盘：之后 App 可能被系统结束，离开页面的 onDisappear 不会再来
        flushToken = services.addBackgroundFlush { await autosave.flush() }
    }
}

/// 变量取值：逐个填写，↩ 提交并关闭；取值存在卡片上。
private struct VariablesSheet: View {
    let card: Card
    let names: [String]
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Group {
                if names.isEmpty {
                    Text("正文里还没有 {{变量}}").foregroundStyle(palette.ink2)
                }
                ForEach(names, id: \.self) { name in
                    LabeledContent("{{\(name)}}") {
                        TextField("取值", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .multilineTextAlignment(.trailing)
                    }
                }
                }
                .listRowBackground(palette.paper)
            }
            .deskBackground()
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
