#if os(macOS)
import SwiftUI

struct NewSessionPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.panel(item: Bindable(workspace).newSession, style: .bare) { NewSessionInput(start: $0) }
    }
}
#endif
