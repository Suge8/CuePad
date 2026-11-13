import CueStore
import SwiftUI

/// 两段一开页就都挂着，换段只换哪一段看得见：不重建，各自的滚动位置留着。第一次换过去也不现建——两段加起来几十行，
/// 开页时一起建，比按段现建（同进展页的 `mounted`）在第一次换段时卡一下、也滑不起来（还没有层可挪）划算。
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
            content()
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

/// 规则｜技能两段，看哪一段只有 `Workspace.libraryPane` 一份（`PaneSegment`）：Mac 在主栏栏头（`LibraryPanesSlot`），
/// 手机与 iPad 在页顶中间那块玻璃里（`LibraryScreen`）；它也是页名，页里不另写。
struct LibraryPanes: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PaneSegment(items: LibraryPane.allCases.map { .init(value: $0, title: $0.title, icon: $0.icon) }, selection: workspace.libraryPane) {
            workspace.libraryPane = $0
        }
    }
}
