#if os(iOS)
import SwiftUI

struct LivePhoneTool: View {
    let session: UUID
    let zoom: Namespace.ID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let button = workspace.liveButton(session) {
            Button(LivePreviewTool.label(button), icon: .livePreview) { workspace.toggleLivePreview() }
                .matchedTransitionSource(id: session, in: zoom)
        }
    }
}

extension View {
    /// 手机上铺满屏的活预览：从页头那颗钮长开、收回（系统的缩放转场），栏在顶上，网页伸到屏幕下缘。
    /// 系统转场自带的下拉、捏合、左缘右滑收起，落在网页里的不算（`PreviewDismissGuard`）。
    func livePhoneCover(_ session: UUID, zoom: Namespace.ID) -> some View {
        modifier(LivePhoneCover(session: session, zoom: zoom))
    }
}

private struct LivePhoneCover: ViewModifier {
    let session: UUID
    let zoom: Namespace.ID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding { workspace.showsLivePreview(session) } set: { if !$0 { workspace.liveCover = nil } }) {
            Group {
                if let preview = workspace.livePreviews[session] {
                    LivePreviewPane(preview: preview).ignoresSafeArea(.container, edges: .bottom)
                        .background((preview.ground ?? palette.desk).ignoresSafeArea())
                        .background { PreviewDismissGuard(web: true) }
                }
            }
            .navigationTransition(.zoom(sourceID: session, in: zoom))
        }
    }
}
#endif
