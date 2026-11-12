#if os(macOS)
import SwiftUI

/// 原地淡入淡出、不从顶边滑进：开合不逐帧排版。
struct NoticeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                NoticeCapsule(notice: notice).transition(.opacity).id(notice.id)
            }
        }
        .animation(Motion.fade, value: workspace.notice)
    }
}
#endif
