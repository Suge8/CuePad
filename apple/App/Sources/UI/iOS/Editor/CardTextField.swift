#if os(iOS)
import CueEditor
import CueStore
import SwiftUI

struct CardTextField: View {
    let card: Card
    let editing: CardEditing
    let theme: CueEditorTheme
    var fits = false
    var editable = true
    var underHeader = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.headerClearance) private var headerClearance

    var body: some View {
        @Bindable var handle = editing.handle
        IOSEditorHost(
            initialText: editing.initialText,
            theme: theme,
            handle: handle,
            onChange: { [editing] in editing.changed($0) },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onError: workspace.fail,
            fits: fits, topInset: underHeader ? headerClearance : 0, bottomInset: fits ? 0 : CardEditorBar.clearance(theme), editable: editable)
        .overlay { AttachmentSpotLayer(spot: handle.spot) }
        .overlay(alignment: .bottom) { if !fits { CardEditorBar(card: card, editing: editing, theme: theme) } }
        .modifier(FileSources(source: $handle.source) { handle.insert($0) })
    }
}

struct CardInsertMenu<Label: View>: View {
    let editing: CardEditing
    @ViewBuilder let label: () -> Label

    var body: some View {
        let handle = editing.handle
        let files = ComposerSource.fileChoices.map { choice in
            ChoiceMenu.Choice(title: choice.title, image: .icon(choice.icon)) { handle.source = choice.source }
        }
        MenuButton(sections: [ChoiceMenu.Section(choices: files)], press: .button, accessibilityLabel: "添加", label: label)
            .fixedSize()
    }
}
#endif
