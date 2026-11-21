import CueStore
import SwiftUI

struct LibraryDeck: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = workspace.libraryPane
        ZStack(alignment: .top) {
            LibraryPaneScroll(pane: .rules, shown: shown) { Self.pane(library) { InstructionSection(library: library) } }
            LibraryPaneScroll(pane: .skills, shown: shown) { Self.pane(library) { SkillSection(library: library) } }
        }
    }

    private static func pane(_ library: AgentLibrary, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: LibraryLayout.gap) {
            content().frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            LibrarySource(library: library)
            #endif
        }
    }
}

private struct LibraryPaneScroll<Content: View>: View {
    let pane: LibraryPane
    let shown: LibraryPane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: LibraryLayout.column)
                .padding(.horizontal, LibraryLayout.margin)
                .padding(.bottom, LibraryLayout.bottom)
                .frame(maxWidth: .infinity)
        }
        .paneTurn(Self.index(pane), of: Self.index(shown))
    }

    private static func index(_ pane: LibraryPane) -> Int { LibraryPane.allCases.firstIndex(of: pane) ?? 0 }
}

struct LibraryPanes: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PaneSegment(items: LibraryPane.allCases.map { .init(value: $0, title: $0.title, icon: $0.icon) }, selection: workspace.libraryPane) {
            workspace.libraryPane = $0
        }
    }
}
