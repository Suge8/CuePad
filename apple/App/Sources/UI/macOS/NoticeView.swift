#if os(macOS)
import SwiftUI

/// 会话条不在时（收起了、窗口放不下）的提示：最顶那一排、主区那一段的正中。会话条在时在它底部（`WideRail`）。
struct NoticeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            NoticeSlot(place: .head(fills: false))
                .padding(.horizontal, Spacing.page)
                .frame(width: sizes.home ? geometry.size.width : sizes.rail + sizes.main, height: Chrome.band)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
#endif
