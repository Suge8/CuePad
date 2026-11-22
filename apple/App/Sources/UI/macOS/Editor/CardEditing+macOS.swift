#if os(macOS)
import CueEditor
import CueStore
import SwiftUI

extension CardEditing {
    func submit() {
        let workspace = workspace
        Task {
            do {
                guard let card = try await flushed(), card.isTask else { return }
                workspace.handOff(card)
            } catch {
                workspace.fail(error)
            }
        }
    }

    func field(_ card: Card, theme: CueEditorTheme) -> some View {
        var editor = host(card, theme: theme)
        editor.bottomInset = CardEditorBar.clearance(theme)
        return editor.overlay { AttachmentSpotLayer(spot: handle.spot) }
            .overlay(alignment: .bottom) { CardEditorBar(card: card, editing: self, theme: theme) }
    }

    func fittedField(_ card: Card, theme: CueEditorTheme) -> some View {
        FittedEditorHost(host: host(card, theme: theme)).overlay { AttachmentSpotLayer(spot: handle.spot) }
    }

    private func host(_ card: Card, theme: CueEditorTheme) -> EditorHost {
        let workspace = workspace
        return EditorHost(
            initialText: initialText, theme: theme, handle: handle,
            onChange: { [weak self] in self?.changed($0) },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onSubmit: { [weak self] in self?.submit() },
            onError: workspace.fail)
    }
}
#endif
