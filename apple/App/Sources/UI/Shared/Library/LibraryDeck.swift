import CueStore
import SwiftUI

/// 技能与规则页的两段（`Workspace.libraryPane`）：规则（`InstructionSection`）与技能（`SkillSection`），各在自己的滚动区里，一列居中（`LibraryLayout`）。
/// 两段一开页就都挂着，换段只换哪一段看得见：不重建，各自的滚动位置留着。第一次换过去也不现建——两段加起来几十行，
/// 开页时一起建，比按段现建（同进展页的 `mounted`）在第一次换段时卡一下、也滑不起来（还没有层可挪）划算。
/// 换段时进来的一段从它在分段里的那一侧滑进来、出去的滑向另一侧（先后即分段的左右）：平移在渲染端（`ContentLift`），透明度随换段的那次动画；
/// 减弱动态效果时不滑、只淡。看不见的那段点不到、读屏跳过。
struct LibraryDeck: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = workspace.libraryPane
        ZStack(alignment: .top) {
            LibraryPaneScroll(pane: .rules, shown: shown) { InstructionSection(library: library) }
            LibraryPaneScroll(pane: .skills, shown: shown) { SkillSection(library: library) }
        }
    }
}

private struct LibraryPaneScroll<Content: View>: View {
    let pane: LibraryPane
    let shown: LibraryPane
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lift = ContentLift()

    /// 滑多远：够看出从哪边来，不至于像整页翻过去。
    private static var slide: CGFloat { 28 }

    var body: some View {
        let on = pane == shown
        ScrollView {
            content
                .frame(maxWidth: LibraryLayout.column)
                .padding(.horizontal, LibraryLayout.margin)
                .padding(.bottom, LibraryLayout.bottom)
                .frame(maxWidth: .infinity)
                .background { ContentLift.Anchor(lift: lift) }
        }
        .opacity(on ? 1 : 0)
        // 出去的那段淡得比进来的快：两段叠着半透明的那几帧短，字不糊在一起
        .transaction(value: on) { if !on, $0.animation != nil { $0.animation = Motion.crossfade } }
        .allowsHitTesting(on)
        .accessibilityHidden(!on)
        .onChange(of: shown) { old, new in
            guard !reduceMotion, old != new, old == pane || new == pane else { return }
            let other = pane == new ? old : new
            let side: CGFloat = pane > other ? Self.slide : -Self.slide
            if pane == new { lift.slideIn(fromX: side) } else { lift.slideOut(toX: side) }
        }
    }
}

/// 规则｜技能两段，看哪一段只有 `Workspace.libraryPane` 一份（`PaneSegment`）：Mac 在工具栏中间（`LibraryPanesSlot`），
/// 手机与 iPad 在页顶中间那块玻璃里（`LibraryScreen`）；它也是页名，页里不另写。
struct LibraryPanes: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PaneSegment(items: LibraryPane.allCases.map { .init(value: $0, title: $0.title, icon: $0.icon) }, selection: workspace.libraryPane) {
            workspace.libraryPane = $0
        }
    }
}
