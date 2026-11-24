#if os(macOS)
import SwiftUI

struct NoticeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let width = sizes.rail + sizes.main
            ZStack(alignment: .top) {
                if workspace.noticeOnHead, let notice = workspace.notice {
                    LinearGradient(stops: [.init(color: palette.desk, location: 0), .init(color: palette.desk, location: 0.75), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Chrome.band + Chrome.scrollFade)
                        .padding(.leading, Chrome.headLead(rail: 0))
                        .padding(.trailing, sizes.cue == 0 ? CueButton.reserve : 0)
                        .allowsHitTesting(notice.takesHits)
                        .transition(.opacity)
                }
                NoticeSlot(place: .head(fills: false)).padding(.horizontal, Spacing.page).frame(height: Chrome.band)
            }
            .frame(width: width, alignment: .top)
            .animation(Motion.fade, value: workspace.noticeOnHead)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
#endif
