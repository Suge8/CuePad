#if os(macOS)
import SwiftUI

/// 主窗口顶部居中的短提示（`NoticeCapsule`）：操作结果与错误。原地淡入淡出、不从顶边滑进：Mac 上开合不逐帧挪位置（docs/layout.md）。
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
