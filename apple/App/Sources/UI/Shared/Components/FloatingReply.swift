import SwiftUI

/// 对话区与浮在它底上的回复框（Mac 对话页；Cue 页三端，连同"等你"卡；手机会话页）：这一块占的高是对话的底部边距
/// （`chatBottomInset`），最新一行停在它上方，看上去与上下排开一样。高记在这里、只往对话里传：卡升起时每帧都变，记在页上的话整页连同对话每帧重算。
/// 不上下排开（也不做成 iOS 底下那一栏）：那样回复框一变矮，对话的可见区就变高，贴着最新的整段对话跟着被拉下来——发出时回复框当下收起、
/// 发出的话要等写进库才到，中间那一两帧就是一下闪动；它一变高（卡升起）系统当帧挪对话、滚动区下一帧才跟上。
/// 浮着时可见区不变，边距由 `ChatScroll` 留到那句到了再一起收。
/// 这一块贴着底：比可见区还高时（键盘很高、输入框撑到好几行）往上伸出去，不把输入框挤到键盘底下。
/// `backed`：这一块铺页底色、盖住身后的对话（Mac）；手机上回复框是玻璃、卡是纸，对话在它们周围清楚可见，不铺。
///
/// 键盘只经系统的安全区让，两页同一套：对话与这一块的底边是安全区底边，键盘弹出时就是键盘顶（第三方键盘长高、换键盘、下拖收起都由系统跟着键盘的动画走），
/// 这一块离它 `gap`。`floor`（窄屏 Cue 页，同 Dock）：下安全区（主屏指示条那一条）不让，对话与这一块伸到屏幕底，这一块离屏幕底边至少 `floor`，
/// 键盘顶高过它就贴着键盘顶，离屏幕底边是 max(floor, 键盘高 + gap)。键盘高在排版里量：放这一块的那层伸过键盘，比对话区高出的那段就是。
/// 不经状态、不看焦点：焦点与键盘不是一回事（外接键盘有焦点没键盘），按焦点切换让不让的话，输入框跟着焦点的动画走、与键盘不同步。
struct FloatingReply<Chat: View, Reply: View>: View {
    var backed = true
    var gap: CGFloat = ChatLayout.replyGap
    var floor: CGFloat?
    @ViewBuilder let chat: Chat
    @ViewBuilder let reply: Reply
    @Environment(\.palette) private var palette
    @State private var height: CGFloat = 0
    @State private var area: CGFloat = .infinity

    var body: some View {
        ZStack(alignment: .bottom) {
            chat.environment(\.chatBottomInset, height)
            GeometryReader { room in
                let keyboard = room.size.height - (room.bounds(of: .named(floatingReplyPage))?.maxY ?? room.size.height)
                reply
                    .padding(.bottom, max((floor ?? 0) - keyboard, gap))
                    .environment(\.chatHeight, area)
                    .frame(maxWidth: .infinity)
                    .background(backed ? palette.desk : .clear)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .padding(.bottom, keyboard)
                    // 框就是给的高，放不下的从顶上伸出去，不伸到键盘底下
                    .frame(width: room.size.width, height: room.size.height, alignment: .bottom)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(floatingReplyPage))
        // 对话透到上安全区里（页头、状态栏底下也是对话），可见的高连同它算；下边不算：键盘弹出时那是键盘，盖住的不可见
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top } action: { area = $0 }
        .ignoresSafeArea(.container, edges: floor == nil ? [] : .bottom)
    }
}

/// 对话区（`FloatingReply`）的坐标：放回复框的那层伸过键盘，拿它量出键盘高。
private let floatingReplyPage = "FloatingReply.page"
