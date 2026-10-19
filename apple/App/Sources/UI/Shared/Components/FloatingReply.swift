import SwiftUI

/// 对话区与浮在它底上的回复框（Mac 对话页；Cue 页三端，连同"等你"卡）：这一块占的高是对话的底部边距
/// （`chatBottomInset`），最新一行停在它上方，看上去与上下排开一样。高记在这里、只往对话里传：卡升起时每帧都变，记在页上的话整页连同对话每帧重算。
/// 不上下排开（也不做成 iOS 底下那一栏）：那样回复框一变矮，对话的可见区就变高，贴着最新的整段对话跟着被拉下来——发出时回复框当下收起、
/// 发出的话要等写进库才到，中间那一两帧就是一下闪动；它一变高（卡升起）系统当帧挪对话、滚动区下一帧才跟上。
/// 浮着时可见区不变，边距由 `ChatScroll` 留到那句到了再一起收。
/// `backed`：这一块铺页底色、盖住身后的对话（Mac）；手机上回复框是玻璃、卡是纸，对话在它们周围清楚可见，不铺。
struct FloatingReply<Chat: View, Reply: View>: View {
    var backed = true
    @ViewBuilder let chat: Chat
    @ViewBuilder let reply: Reply
    @Environment(\.palette) private var palette
    @State private var height: CGFloat = 0
    @State private var area: CGFloat = .infinity

    var body: some View {
        ZStack(alignment: .bottom) {
            chat.environment(\.chatBottomInset, height)
            reply
                .environment(\.chatHeight, area)
                .frame(maxWidth: .infinity)
                .background(backed ? palette.desk : .clear)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 对话透到安全区里（页头、状态栏底下也是对话），可见的高连同安全区算
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { area = $0 }
    }
}
