#if os(macOS)
import SwiftUI

/// 主窗口顶部居中的短提示（`NoticeCapsule`）：操作结果与错误。原地淡入淡出、不从顶边滑进：开合不逐帧排版（docs/layout.md「宽屏开合」）。
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
