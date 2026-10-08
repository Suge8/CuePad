#if os(iOS)
import CueEditor
import CueStore
import CueText
import PhotosUI
import SwiftUI

nonisolated private struct EditorData: Sendable {
    var card: Card
    var project: Project?
    /// 提示词所在的任务（挂在任务下的灵感）。
    var task: Card?
}

/// 打开的灵感或任务：正文编辑（键盘上方是工具栏：分割线、插图、变量取值、发送；选中文字时发送只发选中的部分）与自动保存在这里，
/// 外框分两种：灵感是一整张纸页（宽 iPad 上是居中的纸，两侧露出桌面），顶栏是共用的悬浮顶栏——中间写所属项目（提示词写它的任务）
/// 与"时间 · 资料"，右下一颗"交给 Agent"（⌘↩），右边"⋯"里是分享与 `CardMenu.more`；任务是 `TaskPage`（标题、提示词、子任务）。
/// 提示词离开时什么都没写就不留下（`Workspace.dropIfEmpty`）。
struct CardEditorScreen: View {
    let cardID: UUID
    /// 还没读到卡时先按哪种外框排（任务浮窗里是任务），读到后以卡为准。
    var expectsTask = false
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
    @State private var typing = false

    private static let pageWidth: CGFloat = 760

    var body: some View {
        frame
            .ownsBottomEdge()
            // 菜单项上的快捷键要等菜单打开才生效：⌘↩ 另挂一个不占位的按钮
            .background {
                Button("交给 Agent", action: sendToMac).keyboardShortcut(.return, modifiers: .command)
                    .disabled(data == nil).opacity(0).accessibilityHidden(true)
            }
            .photosPicker(isPresented: $pickingImage, selection: $pickedImage, matching: .images)
            .onChange(of: pickedImage) { insertPicked() }
            .sheet(isPresented: $editingVariables) {
                if let card = data?.card { VariablesSheet(card: card, names: CueVariables.names(in: handle.text ?? liveText)) }
            }
            .observing(services.store, [.cards, .projects], id: cardID, into: $data, onError: workspace.fail) { [cardID] store in
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
            .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { dismiss() } }
            .onAppear(perform: makeAutosave)
            .onDisappear {
                let id = cardID, isPrompt = data?.task != nil
                if let autosave {
                    Task {
                        await autosave.flush()
                        if isPrompt { try? await workspace.dropIfEmpty(id) }
                    }
                }
                if let flushToken { services.removeBackgroundFlush(flushToken) }
            }
    }

    private var wide: Bool { sizeClass == .regular }
    private var isTask: Bool { data?.card.isTask ?? expectsTask }

    @ViewBuilder private var frame: some View {
        if isTask {
            if let data { TaskPage(card: data.card) } else { palette.paper }
        } else {
            editor
                // 灵感最常做的是交给 Agent：贴着正文右下一颗主按钮，写字时让给键盘上方的工具栏
                .overlay(alignment: .bottomTrailing) { if !typing, data != nil { ideaHand.transition(.opacity) } }
                .animation(Motion.quick, value: typing)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
                .frame(maxWidth: wide ? Self.pageWidth : .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.paper, in: .rect(cornerRadius: wide ? 22 : 0, style: .continuous))
                .overlay {
                    if wide { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hair).allowsHitTesting(false) }
                }
                .padding(wide ? EdgeInsets(top: 8, leading: 24, bottom: 0, trailing: 24) : EdgeInsets())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .floatingHeader(data.map(Self.place) ?? "", detail: data.map(Self.detail) ?? "") { actions }
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
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

    /// 顶栏中间：提示词写它的任务，其余写所属项目。
    private static func place(_ data: EditorData) -> String {
        data.task?.title ?? data.project?.name ?? "未分类"
    }

    /// 顶栏的一行："改于 03:36 · 资料"；提示词是"提示词 · 改于 03:36"。
    private static func detail(_ data: EditorData) -> String {
        let marks = [data.card.isPinned ? "资料" : nil].compactMap { $0 }
        return ((data.task != nil ? ["提示词"] : []) + ["改于 \(DateLabel.short(data.card.modifiedAt))"] + marks).joined(separator: " · ")
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

    private var ideaHand: some View {
        AgentHandButton(action: sendToMac).padding(.trailing, 16).padding(.bottom, 16)
    }

    /// 交给 Agent（浮起交给 Agent 的输入框）：选中了文字就只发选中的部分。
    private func sendToMac() {
        guard let card = data?.card else { return }
        let body = handle.selection.map { Outgoing.text(body: $0, values: card.variableValues) } ?? outgoing(card)
        navigation.handToAgent(card, text: body)
    }

    /// 编辑菜单里的选区动作。
    private func selectionActions(_ card: Card) -> [CueSelectionAction] {
        [
            CueSelectionAction(title: "交给 Agent", systemImage: "paperplane") { stored in
                navigation.handToAgent(card, text: Outgoing.text(body: stored, values: card.variableValues))
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

/// 交给 Agent 的主按钮：靛青胶囊（签名色只落在主动作上），在灵感纸页右下。
struct AgentHandButton: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Label("交给 Agent", systemImage: "paperplane.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.onSignature)
                .padding(.horizontal, 18).frame(height: 48)
                .background(palette.signature, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: 0)
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
