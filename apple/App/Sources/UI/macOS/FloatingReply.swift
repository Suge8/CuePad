#if os(macOS)
import SwiftUI

/// Mac 对话页（会话页、Cue 页）的对话区与底下的回复框：回复框浮在对话底上、底色盖住身后的对话，它占的高是对话的底部边距
/// （`chatBottomInset`），最新一行停在它上方，看上去与上下排开一样。
/// 不上下排开：那样回复框一变矮，对话的可见区就变高，贴着最新的整段对话跟着被拉下来——发出时回复框当下收起、发出的话要等写进库才到，
/// 中间那一两帧就是一下闪动。浮着时可见区不变，边距由 `ChatScroll` 留到那句到了再一起收。
struct FloatingReply<Chat: View, Reply: View>: View {
    @ViewBuilder let chat: Chat
    @ViewBuilder let reply: Reply
    @Environment(\.palette) private var palette
    @State private var height: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            chat.environment(\.chatBottomInset, height)
            reply
                .frame(maxWidth: .infinity)
                .background(palette.desk)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
#endif
