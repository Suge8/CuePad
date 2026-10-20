#if os(iOS)
import CueEditor
import CueStore
import CueText
import PhotosUI
import SwiftUI

/// 手机上一段正文的编辑器：键盘上方的工具栏插图（相册）、填变量取值；灵感的纸页与任务气泡里的正文共用。
/// 正文的读写都经 `CardEditing`（编辑器是唯一写者）。
struct CardTextField: View {
    let card: Card
    let editing: CardEditing
    let theme: CueEditorTheme
    @Environment(Workspace.self) private var workspace
    @State private var pickingImage = false
    @State private var pickedImage: PhotosPickerItem?
    @State private var editingVariables = false

    var body: some View {
        IOSEditorHost(
            initialText: editing.initialText,
            theme: theme,
            handle: editing.handle,
            onChange: { [editing] in editing.changed($0) },
            onInsertImage: { pickingImage = true },
            onVariables: { editingVariables = true },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onError: workspace.fail)
        .photosPicker(isPresented: $pickingImage, selection: $pickedImage, matching: .images)
        .onChange(of: pickedImage) { insertPicked() }
        .sheet(isPresented: $editingVariables) {
            VariablesSheet(card: card, names: CueVariables.names(in: editing.handle.text ?? editing.initialText))
        }
    }

    private func insertPicked() {
        guard let item = pickedImage else { return }
        pickedImage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                editing.handle.insertImage(PickedImage.outgoing(data))
            } catch {
                workspace.fail(error)
            }
        }
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
                        TextField("取值", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), palette: palette)
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
        workspace.saveVariables(values, of: card)
        dismiss()
    }
}
#endif
