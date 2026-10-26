import SwiftUI

/// 聊天式的滚动区（会话页与 Cue 页、Mac 与 iPhone 共用，经 `ChatColumn`）：打开停在最新，贴着最新时跟着新内容与底下输入框的长高、键盘的弹出，
/// 用户滚走后这些都不再挪动正在读的内容；离最新处超过一屏时可见区右下角（回复框右上方）浮出圆形"回到最新"，
/// 离开后来过新内容时带一个点，点它回到最新（`ChatFollow`）。离开最新处之后 `followKey` 变了就算来过新内容（`unseen`）：
/// 按离开那一刻的它推出来，不在它每变一次时写状态——内容一帧里连着到几条（同步带回积压、Cue 连说几句）时，每变一次都写的话一帧里更新好几遍。
/// 贴着最新时新内容插进来的那一帧就排在终位（内容变高矮时底锚，`pinned`），从说话那一边的角长出来，不先排在回复框的玻璃后面再滑上来；
/// 发出一句时回复框让出的地方先留着，那句到了一起收（`bottomPadding`），收起回复框与新的一条出现在同一帧。减弱动态效果下滚动不做动画。
/// 本机正在和 iCloud 对（`holding`，回到前台、刚打开时拉到的积压一页页地到）时，贴着最新也先不跟：新的长在可见区下面、看着的不动，
/// 对完再一次滑上来——一页一滑的话整段对话一路往下闪。自己发出一句、点"回到最新"照常立刻去。
///
/// 对话不用懒加载栈、只排最近几条（`PiConversation` 的窗口）：懒加载栈的总高与偏移都是按估计高度推出来的，回答高矮悬殊时
/// 底部锚定会落在内容外、整页空白（WWDC26「Dive into lazy stacks」也说绝对偏移不可靠）；整段排开位置是确定的，
/// 打开时的底部锚点就是最新处。往上翻快到头时在上面再排开一段，多出来的高度当场加到偏移上，正在读的不动（`ChatFollow.prepending`、`ContentLift.scroll`）。
/// 滚动区铺到顶栏、状态栏与回复框后面（iOS 的栏与键盘是安全区，滚动区把它当内容边距），内容在玻璃后面清楚可见。
///
/// 对话排在阅读栏里：最宽 `readingWidth`（含左右 `inset`），在滚动区里居中，上下各留 `edge`。栏的边距只能是滚动区自己的边
/// （`safeAreaPadding`），不能是内容外面的 padding 或居中的框：滚动位置跟着一行（滚动目标）走，内容变了就把那一行
/// 对回可见区的左上角——行若离内容原点有一段边距，整段对话就被横着推出那一段。
/// 不用 `contentMargins` 的原因在 docs/ui.md 布局约束（这里犯过：Cue 页拍板卡那一排件的边被写到对话上，整段左移、上移 16）。
/// `.scrollView` 坐标空间两种边一样不含，对话里按它量的（`CueEndProbe`）不变。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    let readingWidth: CGFloat
    let inset: CGFloat
    /// 贴底与否、请求跳到哪：由放它的页面持有（页面据它收起顶栏、输入框）。
    let follow: Binding<ChatFollow>
    let holding: Bool
    /// 最新一条是新到时要撑上去的那种就是它（`rise`）。
    let arrival: UUID?
    private let content: Content
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.chatBottomInset) var bottomInset
    /// 不从"贴着底边"起：那样内容一变高滚动区自己就一下跳到新的底（打开时停在最新处由 `initialOffset` 的底锚管）。
    @State var position = ScrollPosition()
    @State var offset = ScrollOffset()
    /// 发出那一刻浮着的回复框的高（`toNewest`、`bottomPadding`），发出的话到了（内容在下面长高）就放掉。
    @State var held: CGFloat?
    /// `holding` 期间内容在下面长了、还没滑上去。
    @State var deferred = false
    /// `holding` 期间自己要回到最新（发出一句、点圆钮）：这一次对完之前照常跟着。
    @State var unheld = false
    /// 排到下一帧的那一次上滑（`slide`）：还没滑时页面开始 hold（排它的那次读数早于页面开始 hold 的那次更新）就撤掉、记成欠着的一次。
    @State var sliding: Task<Void, Never>?
    /// 内容在渲染端的平移（`rise`）。
    @State var lift = ContentLift()
    /// 离开最新处那一刻的 `followKey`；在最新处为 nil。
    @State var leftAt: Key?

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, holding: Bool = false, arrival: UUID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        self.holding = holding
        self.arrival = arrival
        self.follow = follow
        self.content = content()
    }

    var body: some View {
        // 边距按滚动区的宽在同一次排版里定（GeometryReader 先拿到自己的尺寸再排里面），不写回状态：
        // 宽屏（iPad、Mac 宽窗口）首帧就是居中的栏，不会先按窄边距排一帧再挪
        GeometryReader { proxy in
            ScrollViewReader { reader in
                let padding = bottomPadding
                ScrollView {
                    content.padding(.bottom, padding).background { ContentLift.Anchor(lift: lift) }
                    // 最新处（`toEnd`）
                    Color.clear.frame(height: 0).id(Self.end)
                }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .alignment)
                    // 贴着最新时内容一变高矮就在同一次排版里停在新的最新处（`pinned`）：新来的一条插进来的那一帧就排在终位、从说话那一边的角长出来，
                    // 不先排在回复框的玻璃后面（被折射成怪字）再滑上来。滚走了、正在和 iCloud 对（`holding`）时不锚，正在读的不动
                    .defaultScrollAnchor(pinned ? .bottom : nil, for: .sizeChanges)
                    // 栏贴着滚动区两边（手机、窄窗口）时，横向滚动的表格可以越过页边距滑到边上（`readingColumnBleeds`）
                    .environment(\.readingColumnBleeds, proxy.size.width <= readingWidth)
                    .safeAreaPadding(.horizontal, margin(proxy.size.width))
                    .safeAreaPadding(.vertical, ChatLayout.edge)
                    // 滚动条不随栏的边缩进：仍贴滚动区的左右边，上下只让开栏与回复框
                    .contentMargins(.horizontal, -margin(proxy.size.width), for: .scrollIndicators)
                    .contentMargins(.top, -ChatLayout.edge, for: .scrollIndicators)
                    .contentMargins(.bottom, bottomInset - ChatLayout.edge, for: .scrollIndicators)
                    .scrollPosition($position)
                    .onScrollPhaseChange { _, phase in
                        let scrolling = phase == .interacting || phase == .decelerating
                        if follow.wrappedValue.scrolling != scrolling { follow.wrappedValue.scrolling = scrolling }
                    }
                    .onScrollGeometryChange(for: Reading.self) { geometry in
                        // 可见区底边 = 偏移 + 顶部 inset + 容器高（containerSize 已扣掉上下 inset）
                        let read = geometry.contentOffset.y + geometry.contentInsets.top
                        let distance = max(0, (geometry.contentSize.height - read - geometry.containerSize.height).rounded())
                        let screen = geometry.containerSize.height.rounded()
                        offset.set(read: max(0, read.rounded()), end: (geometry.contentSize.height - geometry.containerSize.height).rounded(), container: screen)
                        return Reading(
                            nearNewest: distance <= ChatFollow.slack, beyondScreen: distance > screen, nearOldest: read < screen,
                            height: (geometry.contentSize.height - padding).rounded(), floating: padding)
                    } action: { previous, reading in
                        let delivered = offset.deliver(reading)
                        let last = delivered.reading ?? previous
                        let grown = reading.height - last.height
                        // 新到的那一条带来的长高（它插进来的那次排版）：在对、滚走了时它照常长在下面
                        let rising = offset.arrived(arrival) && grown > 0
                        if follow.wrappedValue.prepending, grown > 0 {
                            follow.wrappedValue.prepended()
                            // 贴着最新时正在读的就是最新处：停回新的最新处。按偏移补的话，打开时顶栏边距刚生效、系统把偏移放回了顶上，
                            // 补出来的是顶上那一截
                            if follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling {
                                toEnd(reader)
                                settle(reader, animated: false)
                            } else if let target = follow.wrappedValue.target {
                                // 跳去了某一条、你还没滚过：打开时排开更早的一段常与跳挤在相邻两帧，按偏移补的话晚一拍生效的偏移会盖掉跳，重新对准那一条
                                reader.scrollTo(target.id, anchor: target.anchor)
                            } else { lift.scroll(by: grown) }
                            return
                        }
                        // 跳去了某一条、你还没滚过：内容这时才变高矮（它上面的图读到了真实的比例、更早的一段排开）的话偏移不动、那一条被推走，重新对准它。
                        // 变高矮常晚于跳的那一下：图的比例读到之前按猜的排
                        if grown != 0, !follow.wrappedValue.scrolling, let target = follow.wrappedValue.target {
                            reader.scrollTo(target.id, anchor: target.anchor)
                            return
                        }
                        // 发出的话到了：替回复框留着的留白收起（下一次排版）。只会从有到无，不成排版的反馈环
                        if held != nil, grown > 0 { held = nil }
                        // 贴着最新、用户没在滚时离最新处远了是这里自己要补滚（内容长高、回复框长高、留白收起），补滚途中照"在最新处"报：
                        // 不然贴底状态先变后变回来，读它的对话与页面跟着重算两遍
                        let following = follow.wrappedValue.atNewest && !follow.wrappedValue.scrolling
                        var next = follow.wrappedValue
                        next.scrolled(
                            atNewest: reading.nearNewest || following, beyondScreen: reading.beyondScreen && !following, nearOldest: reading.nearOldest,
                            byUser: next.scrolling)
                        if next != follow.wrappedValue { follow.wrappedValue = next }
                        guard following else { return }
                        if holding, !unheld, grown > 0 {
                            deferred = true
                            return
                        }
                        // 新内容、正在说的话在下面长出来：底锚已在同一次排版里停到新的最新处（`pinned`），不再滑。
                        // 贴着最新却离最新处远了（系统挪的：栏的高度第一次加进内容边距时它把偏移放回顶上）、回复框长高了：直接补滚过去。在读数里补（布局定下来之后）。
                        // 回复框长高不等离远了才补：Mac 打开会话时回复框比占位高，读数已报在底、画面与点按却还停在原处，最后一行压在回复框下、选不中；
                        // 内容或浮着的那块变矮（拍板卡答掉后让出的高一下收起、一格收起）、偏移已越过最新处时也补回去：iOS 的滚动区不一定自己退回来，
                        // 底下空着一截，矮得多时整屏空白。只认变矮：发出一句的那一拍里有一次读数的可见区还没算上两行的输入框，
                        // 按"越过了"补回的话对话先掉下去再滑上来
                        let shrank = grown < 0 || reading.floating < last.floating
                        if grown > 0, reading.nearNewest {
                            // 底锚当帧已排在新的最新处（`pinned`），不再滚；新到的那一条把上面的对话撑上去
                            if rising { rise(by: grown) }
                        } else if Self.followsKeyboard, delivered.viewShrank, grown == 0 {
                            // 可见区从底下变矮、内容没变：键盘升起来了（系统先把它算进内容边距，键盘才开始升）。整段滑上去，
                            // 对话与键盘、回复框一起走；当下补滚的话整段对话先一下跳到终点，键盘与回复框还在半路
                            slide(reader)
                        } else if (!reading.nearNewest && !deferred) || reading.floating > last.floating || (shrank && offset.read > offset.end) {
                            toEnd(reader)
                            settle(reader)
                        }
                    }
                    .onChange(of: follow.wrappedValue.atNewest) { _, atNewest in leftAt = atNewest ? nil : followKey }
                    .onChange(of: holding) {
                        unheld = false
                        if holding, let sliding {
                            sliding.cancel()
                            self.sliding = nil
                            deferred = true
                        }
                        guard !holding, deferred else { return }
                        deferred = false
                        slide(reader)
                    }
                    .onChange(of: follow.wrappedValue.toNewest) { _, request in if let request { toNewest(sent: request.sent, reader) } }
                    // 跳到某一条：按条的 id 在整段内容里找（`ScrollViewReader`；滚动位置的按 id 跳只认滚动目标布局的直接子视图，
                    // 对话分段排（`ChatSegments`），那里只有段）。等这一下顶栏让开、回复框收起排好了再滚：同一次更新里滚，滚动区不动
                    .onChange(of: follow.wrappedValue.target) { _, target in
                        guard let target else { return }
                        Task {
                            await NextFrame.wait()
                            withAnimation(reduceMotion || target.landing == .read ? nil : HandOff.quick) { reader.scrollTo(target.id, anchor: target.anchor) }
                        }
                    }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if follow.wrappedValue.showsJump {
                JumpToNewest(unseen: unseen) { follow.wrappedValue.jumpToNewest() }
                    .padding(.trailing, JumpToNewest.inset).padding(.bottom, JumpToNewest.inset + bottomInset)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: follow.wrappedValue.showsJump)
        .animation(HandOff.quick, value: unseen)
    }
}
