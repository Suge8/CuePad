import SwiftUI

/// 贴着最新（规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底，回到最新处（自己滚回、点"回到最新"）重新贴上；
/// 输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。离最新处超过一屏出"回到最新"圆钮，离开后来了新内容圆钮带一个点。
/// 顶栏让开（`showsHeader`，iPhone 与 Mac 同一条）：离开最新就让开，看历史期间怎么滑都不出现（往回滑也不出来，
/// 免得读的时候顶栏一闪一闪）；点它原来的位置唤出（`reveal`），再滑又让开；回到最新（滑到底、点"回到最新"、发出消息）自动出现。
/// 平台不同的只有"⋯"：iPhone 上跟标题一起让开（顶栏浮在对话上，少一颗圆钮就少一块遮挡，`floatingHeader` 的 `hidden`）；
/// Mac 上只让开标题、"⋯"一直在——Mac 没有状态栏，工具栏本来就一直在，让开只在那组玻璃里留下一格空位。iPhone 的返回钮不在这条规则里，
/// 一直在：看历史时也看得到怎么回去（Mac 没有返回钮，导航在侧栏）。
nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    /// 离最新处超过一屏：出"回到最新"圆钮。
    private(set) var showsJump = false
    /// 离开最新处后来过新内容：圆钮上带一个点。
    private(set) var hasUnseen = false
    /// 离最早那头不到一屏：对话该在上面再排开一段（`SessionChat`）。
    private(set) var nearOldest = false
    /// 正在上面排开更早的一段：内容接下来在上面变高，滚动区把多出来的高度加到偏移上，正在读的不动。
    /// 不能交给滚动区自己：滑到顶时（快甩的惯性常常先到顶）它记下的是"贴着顶边"，新内容会把正在读的推下去。
    private(set) var prepending = false
    /// 请滚动区回到最新的次数（`jumpToNewest`）：滚动区看到它变了就滚过去。
    private(set) var jumps = 0
    /// 请滚动区跳到的那一条（`jump(to:)`）。
    private(set) var target: Target?
    /// 用户正拖着或甩着滚动区（滚动区写入）。
    var scrolling = false
    /// 在看历史时点顶部唤出了顶栏。
    private var revealed = false
    /// 离最新处这么近算"在最新处"。
    static let slack: CGFloat = 24

    /// 标题此刻露着（iPhone 的"⋯"跟着它；返回钮与 Mac 的"⋯"一直在，见上）。
    var showsHeader: Bool { atNewest || revealed }

    struct Target: Equatable {
        let id: UUID
        let request = UUID()
    }

    /// 滚动区此刻离最新处 `distance`、离最早处 `fromOldest`（一屏高 `screen`）；`byUser`：是用户拖着或甩着带来的。
    mutating func scrolled(distance: CGFloat, fromOldest: CGFloat, screen: CGFloat, byUser: Bool) {
        showsJump = distance > screen
        nearOldest = fromOldest < screen
        if distance <= Self.slack {
            atNewest = true
            hasUnseen = false
            revealed = false
        } else if byUser {
            atNewest = false
            revealed = false
        }
    }

    /// 看历史时点屏幕顶部：顶栏出来，直到再滑或回到最新。
    mutating func reveal() {
        if !atNewest { revealed = true }
    }

    mutating func contentChanged() {
        if !atNewest { hasUnseen = true }
    }

    mutating func jumpToNewest() { jumps += 1 }

    mutating func willPrepend() { prepending = true }

    mutating func prepended() { prepending = false }

    /// 跳到某一条去读：不再贴着最新（跳到的就在最新处时，滚到后会重新贴上）。
    mutating func jump(to id: UUID) {
        atNewest = false
        revealed = false
        target = Target(id: id)
    }
}

enum ChatLayout {
    /// 对话最新那头与最早那头的留白：最后一行离回复框（含排队、问题卡）至少这么远。
    static let edge: CGFloat = 16
}

extension EnvironmentValues {
    /// 刚跳到的那条你的话：短暂描一圈（刻度滑条）。
    @Entry var chatHighlight: UUID?
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话页共用）：打开停在最新，贴着最新时跟着新内容与底下输入框的长高、键盘的弹出，
/// 用户滚走后这些都不再挪动正在读的内容；离最新处超过一屏时可见区右下角（回复框右上方）浮出圆形"回到最新"，
/// 离开后来过新内容时带一个点，点它回到最新（`ChatFollow`）。`followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
///
/// 对话不用懒加载栈、只排最近几条（`PiConversation` 的窗口）：懒加载栈的总高与偏移都是按估计高度推出来的，回答高矮悬殊时
/// 底部锚定会落在内容外、整页空白（WWDC26「Dive into lazy stacks」也说绝对偏移不可靠）；整段排开位置是确定的，
/// 底部锚点（`defaultScrollAnchor(.bottom)`）就是最新处。往上翻快到头时在上面再排开一段，多出来的高度加到偏移上，正在读的不动（`ChatFollow.prepending`）。
/// 滚动区铺到顶栏、状态栏与回复框后面（iOS 的栏与键盘是安全区，滚动区把它当内容边距），内容在玻璃后面清楚可见。
///
/// 对话排在阅读栏里：最宽 `readingWidth`（含左右 `inset`），在滚动区里居中，上下各留 `edge`。栏的边距只能是滚动区的
/// 内容边距（`contentMargins`），不能是内容外面的 padding 或居中的框：滚动位置跟着一行（滚动目标）走，内容变了就把那一行
/// 对回可见区的左上角——行若离内容原点有一段边距，整段对话就被横着推出那一段。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    private let readingWidth: CGFloat
    private let inset: CGFloat
    private let external: Binding<ChatFollow>?
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var own = ChatFollow()

    /// `follow`：页面要据贴底与否改别处（收起顶栏、输入框）时由页面持有；不给就自己持有。
    init(followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>? = nil, @ViewBuilder content: () -> Content) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        external = follow
        self.content = content()
    }

    /// 阅读栏两边的边距：窄时是 `inset`，宽时把栏居中。
    private func margin(_ width: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }

    private var follow: Binding<ChatFollow> { external ?? $own }

    var body: some View {
        // 边距按滚动区的宽在同一次排版里定（GeometryReader 先拿到自己的尺寸再排里面），不写回状态：
        // 宽屏（iPad、Mac 宽窗口）首帧就是居中的栏，不会先按窄边距排一帧再挪
        GeometryReader { proxy in
            ScrollView { content }
                .defaultScrollAnchor(.bottom)
                // 栏贴着滚动区两边（手机、窄窗口）时，横向滚动的表格可以越过页边距滑到边上（`readingColumnBleeds`）
                .environment(\.readingColumnBleeds, proxy.size.width <= readingWidth)
                .contentMargins(.horizontal, margin(proxy.size.width), for: .scrollContent)
                .contentMargins(.vertical, ChatLayout.edge, for: .scrollContent)
                .scrollPosition($position)
                .onScrollPhaseChange { _, phase in follow.wrappedValue.scrolling = phase == .interacting || phase == .decelerating }
                .onScrollGeometryChange(for: Reading.self) { geometry in
                    // 可见区底边 = 偏移 + 顶部 inset + 容器高（containerSize 已扣掉上下 inset）
                    let read = geometry.contentOffset.y + geometry.contentInsets.top
                    return Reading(
                        distance: max(0, (geometry.contentSize.height - read - geometry.containerSize.height).rounded()),
                        fromOldest: max(0, read.rounded()),
                        height: geometry.contentSize.height.rounded(),
                        screen: geometry.containerSize.height.rounded(),
                        end: (geometry.contentSize.height - geometry.containerSize.height).rounded(), inset: geometry.contentInsets.top.rounded())
                } action: { previous, reading in
                    if follow.wrappedValue.prepending, reading.height > previous.height {
                        follow.wrappedValue.prepended()
                        position.scrollTo(y: previous.fromOldest + reading.height - previous.height)
                        return
                    }
                    follow.wrappedValue.scrolled(distance: reading.distance, fromOldest: reading.fromOldest, screen: reading.screen, byUser: follow.wrappedValue.scrolling)
                    // 底锚只管内容变高；回复框长高、键盘弹出、栏的高度第一次加进内容边距（这一下系统把偏移放回顶上），
                    // 都会离开底：贴着最新就补滚到底。在读数里补（布局定下来之后）
                    if reading.distance > 0, follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling {
                        settle(end: reading.end)
                    }
                }
                .onChange(of: followKey) { follow.wrappedValue.contentChanged() }
        }
        .overlay(alignment: .bottomTrailing) {
            if follow.wrappedValue.showsJump {
                JumpToNewest(unseen: follow.wrappedValue.hasUnseen) { follow.wrappedValue.jumpToNewest() }
                    .padding(.trailing, JumpToNewest.inset).padding(.bottom, JumpToNewest.inset)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: follow.wrappedValue.showsJump)
        .animation(Motion.quick, value: follow.wrappedValue.hasUnseen)
        .onChange(of: follow.wrappedValue.jumps) { toNewest() }
        .onChange(of: follow.wrappedValue.target) { _, target in
            guard let target else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { position.scrollTo(id: target.id, anchor: .center) }
        }
    }

    /// 离最新处多远、一屏多高（取整：亚像素的抖动不触发更新）。
    private struct Reading: Equatable {
        var distance: CGFloat
        var fromOldest: CGFloat
        var height: CGFloat
        var screen: CGFloat
        /// 滚到最新处时可见区顶边在内容里的位置（`scrollTo(y:)` 的 y，不含内容边距）。
        var end: CGFloat
        /// 顶部的内容边距：它一变系统就把偏移放回顶上，读数要跟着变，才会再补滚一次。
        var inset: CGFloat
    }

    /// 补滚到底。同一个请求再发一次时滚动位置的值不变、滚动区不动（偏移被内容边距的变化挪走、用户又没碰过时就是这样），
    /// 所以在"滚到底边"与"滚到底部那一点"两种等价的写法之间换着发。
    private func settle(end: CGFloat) {
        if position.edge == .bottom { position.scrollTo(y: end) } else { position.scrollTo(edge: .bottom) }
    }

    private func toNewest() {
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(Motion.quick) { position.scrollTo(edge: .bottom) }
        }
    }
}

/// "回到最新"：回复框右上方一颗圆形玻璃钮，向下的箭头；离开后来过新内容时右上角带一个墨色的点。
struct JumpToNewest: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    /// 点按区的边长与离可见区右、下边的距离。
    static let size: CGFloat = 44
    static let inset: CGFloat = 10
    /// 它在可见区底部占的高（含上下留白）：右缘刻度区的下沿让到这之上。
    static var clearance: CGFloat { size + 2 * inset }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down").font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                .frame(width: 40, height: 40)
                .glass(in: .circle, interactive: true)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(palette.accent).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(palette.desk, lineWidth: 2))
                            .offset(x: -3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseen ? "回到最新，有新内容" : "回到最新")
    }
}
