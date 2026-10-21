import SwiftUI

/// 会话页里上下文压缩过的地方：两边细线、中间一行居中的小字写这里换了什么（`ChatMarker`）；它以上的话 Agent 不再逐句看得到。
/// 刻度滑条上它是一个点（`ChatMark.Kind.boundary`），从滑条跳过来时垫一层选中色。
struct ContextBoundary: View {
    let title: String
    var highlighted = false
    @Environment(\.palette) private var palette

    var body: some View {
        ChatMarker(ruled: true, highlighted: highlighted, action: nil) {
            HStack(spacing: 5) {
                Image(.renew).imageScale(.small)
                Text(title).foregroundStyle(palette.ink2)
            }
        }
    }
}
