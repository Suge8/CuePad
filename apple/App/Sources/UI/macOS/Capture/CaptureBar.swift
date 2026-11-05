#if os(macOS)
import SwiftUI

/// 主窗口底部浮着的随手记：平时一行，占位写明落到哪；聚焦或有内容时展开（左上落点、图片）。
struct CaptureBar: View {
    let project: UUID?
    @State private var capture = CaptureState()

    private static let width: CGFloat = 620
    /// 页底给它让出的高（项目页）：展开时（左上落点一排、两三行字、工具排）连同离窗口底的那一截，最后一张卡能滚到它上面。
    static let clearance: CGFloat = 150

    var body: some View {
        CaptureComposer(state: $capture, defaultProject: project, pinnedOpen: false)
            .frame(maxWidth: Self.width)
            .padding(.horizontal, Spacing.page)
    }
}
#endif
