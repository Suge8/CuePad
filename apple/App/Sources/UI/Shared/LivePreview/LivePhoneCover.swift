#if os(iOS)
import SwiftUI

/// 手机页头的活预览钮：会话有页面可看时才在（`Workspace.liveButton`，Mac 答来的）。点了这一页从它长开铺满屏（`livePhoneCover`）。
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
                    // 状态栏那一条铺页面的底：栏上下接着的是同一张页面，不是一条桌面色
                    LivePreviewPane(preview: preview).ignoresSafeArea(.container, edges: .bottom)
                        .background((preview.ground ?? palette.desk).ignoresSafeArea())
                }
            }
            .navigationTransition(.zoom(sourceID: session, in: zoom))
        }
    }
}
#endif
