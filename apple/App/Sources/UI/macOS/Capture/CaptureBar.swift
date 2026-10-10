#if os(macOS)
import SwiftUI

/// 主窗口底部浮着的随手记：平时一行，占位写明落到哪；聚焦或有内容时展开（左上落点、图片）。
struct CaptureBar: View {
    let project: UUID?
    @State private var capture = CaptureState()

    private static let width: CGFloat = 620

    var body: some View {
        CaptureComposer(state: $capture, defaultProject: project, pinnedOpen: false)
            // 浮在卡片墙上：背后的字不透到输入框里
            .environment(\.composerInk, .solid)
            .frame(maxWidth: Self.width)
            .padding(.horizontal, 24)
    }
}
#endif
