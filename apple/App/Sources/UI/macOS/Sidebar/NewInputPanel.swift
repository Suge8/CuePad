#if os(macOS)
import SwiftUI

struct NewInputPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let from: CGPoint? = if case .press(let point, _) = workspace.press.source { point } else { nil }
        return content
            .panel(item: Bindable(workspace).newSession, style: .bare(from: from)) { NewSessionInput(start: $0) }
            .panel(item: Bindable(workspace).newTask, style: .bare(from: from)) { NewTaskInput(start: $0) }
    }
}
#endif
