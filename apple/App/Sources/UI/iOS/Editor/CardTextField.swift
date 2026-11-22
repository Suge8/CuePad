#if os(iOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

struct CardTextField: View {
    let card: Card
    let editing: CardEditing
    let theme: CueEditorTheme
    var fits = false
    var editable = true
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var handle = editing.handle
        IOSEditorHost(
            initialText: editing.initialText,
            theme: theme,
            handle: handle,
            onChange: { [editing] in editing.changed($0) },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onError: workspace.fail,
            fits: fits, bottomInset: fits ? 0 : plusMargin + FloatingGlyph.size + Spacing.item, editable: editable)
        .overlay { AttachmentSpotLayer(spot: handle.spot) }
        .overlay(alignment: .bottomLeading) {
            if !fits, handle.focused {
                CardInsertMenu(editing: editing) { FloatingGlyph(icon: .add) }
                    .padding([.leading, .bottom], plusMargin)
                    .transition(Motion.pop(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: handle.focused)
        .modifier(FileSources(source: $handle.source) { handle.insert($0) })
        .sheet(isPresented: $handle.editingVariables) {
            VariablesSheet(card: card, names: CueVariables.names(in: handle.text ?? editing.initialText))
        }
    }

    private var plusMargin: CGFloat { theme.horizontalInset - (FloatingGlyph.size - FloatingGlyph.face) / 2 }
}

struct CardInsertMenu<Label: View>: View {
    let editing: CardEditing
    @ViewBuilder let label: () -> Label

    var body: some View {
        let handle = editing.handle
        let files = ComposerSource.fileChoices.map { choice in
            ChoiceMenu.Choice(title: choice.title, image: .icon(choice.icon)) { handle.source = choice.source }
        }
        let variables = editing.hasVariables
            ? [ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "变量取值", image: .icon(.variables)) { handle.editingVariables = true }])] : []
        MenuButton(sections: [ChoiceMenu.Section(choices: files)] + variables, press: .button, accessibilityLabel: "添加", label: label)
            .fixedSize()
    }
}

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
                        TextField(String(localized: "取值"), text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), palette: palette)
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
