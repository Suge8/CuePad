#if os(macOS)
import SwiftUI

/// 会话条不在时（收起了、窗口放不下）的提示：最顶那一排、主区那一段的正中。会话条在时在它底部（`WideRail`）。
/// 这一排的栏头给它让开（同手机）：Mac 的栏头各页各样（看板的列头、会话的名字、Cue 的名牌），不逐个教它们让，由这里拿一条桌面色把主区这一排整条盖住，
/// 下沿化开；盖着的时候这一排不接点按，开合钮与 Cue 钮在这一条的两头外面、照常能点。
struct NoticeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 盖过名牌（比这一排高出一截）再化开的那一段。
    private static let fade = Spacing.block

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let width = sizes.home ? geometry.size.width : sizes.rail + sizes.main
            ZStack(alignment: .top) {
                if workspace.noticeOnHead {
                    LinearGradient(stops: [.init(color: palette.desk, location: 0), .init(color: palette.desk, location: 0.75), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Chrome.band + Self.fade)
                        .padding(.leading, Chrome.headLead(rail: 0))
                        .padding(.trailing, sizes.cue == 0 ? CueButton.reserve : 0)
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
