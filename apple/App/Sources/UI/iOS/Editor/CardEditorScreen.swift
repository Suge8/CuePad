#if os(iOS)
import CueEditor
import CueStore
import CueText
import PhotosUI
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
}

/// 打开的灵感或任务：正文编辑（键盘上方是工具栏：分割线、插图、变量取值）与自动保存在这里，
/// 外框分两种：灵感是一整张纸页（宽 iPad 上是居中的纸，两侧露出桌面），顶栏是共用的悬浮顶栏——中间写所属项目
/// 与"时间 · 资料"，右边"⋯"里是分享与 `CardMenu.more`；任务是 `TaskPage`（标题、正文、步骤）。
/// `part` 是 `.rest` 时是任务页弹出的正文编辑（同一种纸页，只写标题下面的话，顶栏写任务的标题）。
/// 灵感离开时什么都没写就不留下（`Workspace.leaveEditing`）。
struct CardEditorScreen: View {
    let cardID: UUID
    var part = CardTextPart.whole
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: EditorData?
    @State private var initialText: String?
    @State private var handle = IOSEditorHandle()
    @State private var autosave: Autosave?
    @State private var pickingImage = false
    @State private var pickedImage: PhotosPickerItem?
    @State private var editingVariables = false
    @State private var flushToken: UUID?

    private static let pageWidth: CGFloat = 760

    var body: some View {
        frame
            .photosPicker(isPresented: $pickingImage, selection: $pickedImage, matching: .images)
            .onChange(of: pickedImage) { insertPicked() }
            .sheet(isPresented: $editingVariables) {
                if let card = data?.card { VariablesSheet(card: card, names: CueVariables.names(in: currentText)) }
            }
            .observing(services.store, id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
                guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
                return EditorData(card: card, project: try card.projectID.flatMap { try store.project($0) })
            }
            .onChange(of: data?.card.id, initial: true) {
                guard initialText == nil, let card = data?.card else { return }
                initialText = part.text(of: card)
            }
            .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { dismiss() } }
            .onAppear(perform: makeAutosave)
            .onDisappear {
                workspace.leaveEditing(cardID, flush: autosave)
                if let flushToken { services.removeBackgroundFlush(flushToken) }
            }
    }

    private var wide: Bool { sizeClass == .regular }
    @ViewBuilder private var frame: some View {
        if let data, data.card.isTask, part == .whole {
            TaskPage(card: data.card)
        } else {
            editor
                .frame(maxWidth: wide ? Self.pageWidth : .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.paper, in: .rect(cornerRadius: wide ? 22 : 0, style: .continuous))
                .overlay {
                    if wide { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hair).allowsHitTesting(false) }
                }
                .padding(wide ? EdgeInsets(top: 8, leading: 24, bottom: 0, trailing: 24) : EdgeInsets())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .floatingHeader(data.map(place) ?? "", detail: data.map(detail) ?? "") { actions }
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let initialText {
                IOSEditorHost(
                    initialText: initialText,
                    theme: .editor(palette, horizontalInset: inset),
                    handle: handle,
                    onChange: { autosave?.changed($0) },
                    onInsertImage: { pickingImage = true },
                    onVariables: { editingVariables = true },
                    selectionActions: selectionActions(data.card),
                    onError: workspace.fail)
            }
        }
    }

    private var inset: CGFloat { wide ? 44 : 20 }

    /// 顶栏中间：任务的正文写任务的标题，其余写所属项目。
    private func place(_ data: EditorData) -> String {
        part == .rest ? data.card.title : data.project?.name ?? CaptureCopy.unfiled
    }

    /// 顶栏的一行："改于 03:36 · 资料"；任务的正文是"正文 · 改于 03:36"。
    private func detail(_ data: EditorData) -> Dotted {
        Dotted(part == .rest ? "正文" : nil, "改于 \(DateLabel.short(data.card.modifiedAt))", data.card.isPinned ? "资料" : nil)
    }

    /// 顶栏右边的"⋯"：从第一帧就在（卡片还没读到时禁用），随放大过渡一起出现，不在过渡结束后才弹出来。
    private var actions: some View {
        Menu("更多", systemImage: "ellipsis") {
            if let card = data?.card {
                ShareLink(item: outgoing(card)) { Label("分享", systemImage: "square.and.arrow.up") }
                Divider()
                CardActions(card: card, more: true)
            }
        }
        .disabled(data == nil)
    }

    /// 编辑菜单里的选区动作：转为任务。
    private func selectionActions(_ card: Card) -> [CueSelectionAction] {
        [CueSelectionAction(title: "转为任务", systemImage: "checklist") { stored in workspace.convertToTasks(stored, in: card.projectID) }]
    }

    /// 当前编辑中的整张正文（未保存的也算）：编辑器是正文的唯一写者，从它读；编辑器还没建好时是打开时的正文。
    /// 不另存一份跟着每个字更新的状态：存了就是每敲一个字整页重算一遍。
    private var currentText: String { handle.text ?? initialText ?? "" }

    /// 当前编辑中的整张正文，变量已填。
    private func outgoing(_ card: Card) -> String {
        Outgoing.text(body: currentText, values: card.variableValues)
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
        let store = services.store, id = cardID, part = part
        let autosave = Autosave(
            save: { text in try await store.updateCard(id) { part.write(text, into: &$0) } },
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
