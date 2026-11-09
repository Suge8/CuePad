import SwiftUI

/// 这一块占的高是对话的底部边距（`chatBottomInset`），最新一行停在它上方，看上去与上下排开一样。高记在这里、只往对话里传：卡升起时每帧都变，记在页上的话整页连同对话每帧重算。
/// 不上下排开（也不做成 iOS 底下那一栏）：那样回复框一变矮，对话的可见区就变高，贴着最新的整段对话跟着被拉下来——发出时回复框当下收起、
/// 发出的话要等写进库才到，中间那一两帧就是一下闪动；它一变高（卡升起）系统当帧挪对话、滚动区下一帧才跟上。
/// 浮着时可见区不变，边距由 `ChatScroll` 留到那句到了再一起收。
/// 这一块不铺整宽的底：铺一块页底色的话，对话在这一块上沿被一刀横着切掉，和卡、框的圆角不搭。Mac 上卡与框后面垫一块同宽的托底（`replyTray`），
/// 对话只从这一叠上沿的圆角两侧露出来；手机上回复框是玻璃、卡是纸，对话在它们周围清楚可见（docs/layout.md「沉浸式的栏」）。
/// 键盘只经系统的安全区让，两页同一套：对话与这一块的底边是安全区底边，键盘弹出时就是键盘顶（第三方键盘长高、换键盘、下拖收起都由系统跟着键盘的动画走），
/// 这一块离键盘或安全区底边（Mac 是栏底）`Spacing.replyBottom`，各页不另加。键盘高在排版里量，不经焦点状态：外接键盘有焦点也没有软键盘。
struct FloatingReply<Chat: View, Reply: View>: View {
    @ViewBuilder let chat: Chat
    @ViewBuilder let reply: Reply
    /// 这一块的高。量到之前不排对话（同一次更新里的下一遍排版就量到了，第一帧照样有对话）：对话第一次排就按它让出底边，
    /// 不先按 0 排一遍再挪——那样滚动区的读数在打开的那一帧里多变一次，赶上推入页面时导航栏那一遍，系统丢掉第三次（`ChatScroll`）。
    @State private var height: CGFloat?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let height { chat.environment(\.chatBottomInset, height) }
            GeometryReader { room in
                let page = room.bounds(of: .named(floatingReplyPage))?.maxY ?? room.size.height
                let keyboard = room.size.height - page
                reply
                    .padding(.bottom, Spacing.replyBottom)
                    // 对话区可见的高：透到上安全区里（页头、状态栏底下也是对话）的那段连同算；下边不算，键盘弹出时那是键盘，盖住的不可见。
                    // 与键盘高同在这一遍排版里定，不写回状态
                    .environment(\.chatHeight, page + room.safeAreaInsets.top)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .padding(.bottom, keyboard)
                    // 框就是给的高，放不下的从顶上伸出去，不伸到键盘底下
                    .frame(width: room.size.width, height: room.size.height, alignment: .bottom)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(floatingReplyPage))
    }
}

private let floatingReplyPage = "FloatingReply.page"

#if os(macOS)
extension View {
    /// 挂在页给这一叠加左右边距之前：铺整宽就又是一刀平切。卡升起时这一叠的高跟着卡的顶边长（`RiseBehind`），托底的上沿也就是卡的上沿。
    /// 否决了把卡坐进输入框、共用一块纸：卡是纸、框是玻璃，合成一块要改设计系统的层，卡的叠边、升起与会话页几张问题卡也都得跟着改。
    func replyTray() -> some View { modifier(ReplyTray()) }
}

private struct ReplyTray: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.background {
            UnevenRoundedRectangle(topLeadingRadius: Radius.field, topTrailingRadius: Radius.field)
                .fill(palette.desk)
                .padding(.bottom, -Spacing.replyBottom)
        }
    }
}
#endif

