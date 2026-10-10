import SwiftUI

/// 贴着最新（规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底，回到最新处（自己滚回、点"回到最新"）重新贴上；
/// 输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。离最新处超过一屏出"回到最新"圆钮，离开后来了新内容圆钮带一个点。
/// 顶栏：离开最新就让开，看历史期间怎么滑都不出现（往回滑也不出来，免得读的时候顶栏一闪一闪）；点屏幕顶部唤出（`reveal`），
/// 再滑又让开；回到最新（滑到底、点"回到最新"、发出消息）自动出现。
nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    /// 离最新处超过一屏：出"回到最新"圆钮。
    private(set) var showsJump = false
    /// 离开最新处后来过新内容：圆钮上带一个点。
    private(set) var hasUnseen = false
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

    var showsHeader: Bool { atNewest || revealed }

    struct Target: Equatable {
        let id: UUID
        let request = UUID()
    }

    /// 滚动区此刻离最新处 `distance`（一屏高 `screen`）；`byUser`：是用户拖着或甩着带来的。
    mutating func scrolled(distance: CGFloat, screen: CGFloat, byUser: Bool) {
        showsJump = distance > screen
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
    /// 在倒置的聊天滚动区里（iOS）：内容按新到旧给出，每一行用 `chatRow()` 转回正向。
    @Entry var chatInverted = false
    /// 倒置的聊天滚动区底下（回复框与键盘）占的高：对话在懒加载栈里以最新那头的一行空白让出它（见 `ChatScroll`）。
    @Entry var chatBottomSpace: CGFloat = 0
    /// 滚动区贴着最新（`ChatFollow.atNewest`）：Mac 的对话据此知道最上面一行进了可见区是不是因为排开的几条铺不满一屏。
    @Entry var chatAtNewest = true
    /// 刚跳到的那条你的话：短暂描一圈（刻度滑条）。
    @Entry var chatHighlight: UUID?
}

extension View {
    /// 聊天滚动区里的一行：滚动区倒置时把它转回正向。
    func chatRow() -> some View { modifier(ChatRow()) }

    /// 聊天里一条消息的长按菜单（Mac 右键），`preview` 是抬起后的预览。倒置的滚动区里（iOS）按下与抬起用的是这条消息的快照，
    /// 系统按挂菜单那一层的坐标去拍，算不进滚动区那层 180° 翻转，快照倒着出现、再转正。菜单挂在一层反向翻转里，
    /// 快照就是正的；屏幕上两层翻转相抵，消息本身不动。
    func chatContextMenu<Menu: View, Preview: View>(
        @ViewBuilder menu: @escaping () -> Menu, @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        modifier(ChatContextMenu(menu: menu, preview: preview))
    }
}

private struct ChatContextMenu<Menu: View, Preview: View>: ViewModifier {
    let menu: () -> Menu
    let preview: () -> Preview
    @Environment(\.chatInverted) private var inverted

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(inverted ? 180 : 0))
            .contextMenu(menuItems: menu, preview: preview)
            .rotationEffect(.degrees(inverted ? 180 : 0))
    }
}

private struct ChatRow: ViewModifier {
    @Environment(\.chatInverted) private var inverted
    func body(content: Content) -> some View { content.rotationEffect(.degrees(inverted ? 180 : 0)) }
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话页共用）：打开停在最新，贴着最新时跟着新内容与底下输入框的长高、键盘的弹出，
/// 用户滚走后这些都不再挪动正在读的内容；离最新处超过一屏时可见区右下角（回复框右上方）浮出圆形"回到最新"，
/// 离开后来过新内容时带一个点，点它回到最新（`ChatFollow`）。
/// `followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
///
/// iOS 上整个滚动区倒过来（转 180°，最新在偏移 0 处），内容按新到旧给出：打开、跟随、回到最新都是滚到偏移 0，
/// 懒加载从最新那条起排，估计高度只用在最旧的那一头、看不见的地方。正着排时最新在内容末端，它的位置要靠懒加载按估计高度
/// 推算：回答高矮悬殊（整页粘贴的长消息、长代码块）时打开或长距离滚回最新都会落在内容外、整页空白。
/// Mac 不倒置：滚轮不随画面翻转，倒置后滚动方向会反；所以 Mac 的对话不用懒加载，只排最近几条（`PiConversation.window`），底锚点定位。
///
/// 对话排在阅读栏里：最宽 `readingWidth`（含左右 `inset`），在滚动区里居中，上下各留 `edge`。栏的边距只能是滚动区的
/// 内容边距（`contentMargins`），不能是内容外面的 padding 或居中的框：滚动位置跟着一行（滚动目标）走，内容变了就把那一行
/// 对回可见区的左上角——行若离内容原点有一段边距，整段对话就被横着推出那一段（打开会话时整页右偏 16pt、气泡贴到屏幕边），
/// 竖着吃掉最新那头的留白。内容边距在可见区的坐标里，行对回去正好是静止的位置。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    private let readingWidth: CGFloat
    private let inset: CGFloat
    private let clearsBelow: CGFloat
    private let external: Binding<ChatFollow>?
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: Self.newestEdge)
    @State private var own = ChatFollow()
    /// 底下回复框与键盘占的高（iOS）。
    @State private var below: CGFloat = 0

    /// `follow`：页面要据贴底与否改别处（收起顶栏、输入框）时由页面持有；不给就自己持有。
    /// `clearsBelow`（iOS）：最底下这么高（回复框下沿到屏幕底：横条区或键盘）不露对话，内容在回复框下沿淡到全透；
    /// 看历史时（回复框收成短胶囊）整条回复框那一段都不露，胶囊两旁没有被切开的半截气泡。
    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, clearsBelow: CGFloat = 0, follow: Binding<ChatFollow>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.followKey = followKey
        self.clearsBelow = clearsBelow
        self.readingWidth = readingWidth
        self.inset = inset
        external = follow
        self.content = content()
    }

    /// 阅读栏两边的边距：窄时是 `inset`，宽时把栏居中。
    private func margin(_ width: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }

    private var follow: Binding<ChatFollow> { external ?? $own }

    #if os(iOS)
    private static var inverted: Bool { true }
    #else
    private static var inverted: Bool { false }
    #endif
    private static var newestEdge: Edge { inverted ? .top : .bottom }
    /// 贴着最新时回复框下沿之上淡出的一段（在回复框玻璃后面）；看历史时回复框上沿之上淡出的一段。
    private static var fade: CGFloat { 12 }
    private static var historyFade: CGFloat { 24 }

    var body: some View {
        // 滚动区自己铺到屏幕底（见 `scroll`），外框仍是两条栏之间：浮在上面的"回到最新"与页面叠的东西都按可见区摆
        Color.clear
            .background { scroll }
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

    @ViewBuilder private var scroll: some View {
        #if os(iOS)
        // 滚动区铺到屏幕底、不随底下的回复框与键盘缩放：滚动区缩放时可见内容跟着框底一起挪，看历史时一点输入框、多打一行，
        // 正在读的就被往上挤。它们占的高由对话在最新那头的一行空白让出：懒加载栈在可见区以外的行变高时补偏移，正在读的纹丝不动；
        // 贴着最新时滚动区停在起点，最新一行跟着回复框上沿走（离起点还差一点时补滚过去）
        tracked(ScrollView { content.environment(\.chatBottomSpace, below) }.newestFirstScroll())
            .onChange(of: below) { if follow.wrappedValue.atNewest { position.scrollTo(edge: Self.newestEdge) } }
            .newestFirst()
            .ignoresSafeArea(edges: .bottom)
            // 回复框下面那一条（横条区）不露半截气泡；看历史时回复框收成居中的短胶囊，两旁空着，整段回复框的高也不露。
            // 只是内容的透明度遮罩，栏外不画颜色；只随这段高度与贴不贴最新变，滚动时不重算。
            // 切换时各段的高度不变、只淡入淡出回复框那一段：高度跟着动画走时，收起中的胶囊两旁会先露出几帧没被遮住的整字
            .mask {
                let band = max(0, below - clearsBelow)
                ZStack {
                    // 看历史时的样子：回复框上沿之上淡出，回复框那一段与横条区都不露
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.historyFade)
                        Color.clear.frame(height: band + clearsBelow)
                    }
                    .ignoresSafeArea()
                    // 贴着最新时叠上回复框那一段：内容透在回复框玻璃后面，到回复框下沿才淡出
                    VStack(spacing: 0) {
                        Color.clear
                        Rectangle().frame(height: Self.historyFade + max(0, band - Self.fade))
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: min(band, Self.fade))
                        Color.clear.frame(height: clearsBelow)
                    }
                    .ignoresSafeArea()
                    .opacity(follow.wrappedValue.atNewest ? 1 : 0)
                    .animation(Motion.quick, value: follow.wrappedValue.atNewest)
                }
            }
            // 铺满后伸进底下的那一段就是回复框与键盘占的高
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { below = $0 }
        #else
        tracked(ScrollView { content.environment(\.chatAtNewest, follow.wrappedValue.atNewest) }.defaultScrollAnchor(.bottom))
        #endif
    }

    private func tracked(_ scroll: some View) -> some View {
        // 边距按滚动区的宽在同一次排版里定（GeometryReader 先拿到自己的尺寸再排里面），不写回状态：
        // 宽屏（iPad、Mac 宽窗口）首帧就是居中的栏，不会先按窄边距排一帧再挪
        GeometryReader { proxy in
            scroll
                // 栏贴着滚动区两边（手机、窄窗口）时，横向滚动的表格可以越过页边距滑到边上（`readingColumnBleeds`）
                .environment(\.readingColumnBleeds, proxy.size.width <= readingWidth)
                .contentMargins(.horizontal, margin(proxy.size.width), for: .scrollContent)
            .contentMargins(.vertical, ChatLayout.edge, for: .scrollContent)
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in follow.wrappedValue.scrolling = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: Reading.self) { geometry in
                // containerSize 已扣掉上下 inset：倒置时最新在偏移 0 处；正着排时可见区底边 = 偏移 + 顶部 inset + 容器高
                let read = geometry.contentOffset.y + geometry.contentInsets.top
                let distance = Self.inverted ? read : geometry.contentSize.height - read - geometry.containerSize.height
                return Reading(
                    distance: max(0, distance.rounded()), screen: geometry.containerSize.height.rounded(),
                    end: (geometry.contentSize.height - geometry.containerSize.height).rounded())
            } action: { _, reading in
                follow.wrappedValue.scrolled(distance: reading.distance, screen: reading.screen, byUser: follow.wrappedValue.scrolling)
                // 正着排时底锚只管内容变高；底下回复框长高（多一行、带上卡片）是滚动区变矮，滚动区按顶边留住偏移、离开了底：
                // 贴着最新就补滚到底。在读数里补（布局定下来之后），按偏移给（`scrollTo(edge:)` 与上次相同时不再生效，y 已含顶部 inset）
                if !Self.inverted, reading.distance > 0, follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling {
                    position.scrollTo(y: reading.end)
                }
            }
            .onChange(of: followKey) {
                // 倒置时贴着最新就跟上去，没贴着就保持位置、亮出按钮（正着排时由底部锚点贴底）
                if Self.inverted, follow.wrappedValue.atNewest { toNewest() }
                follow.wrappedValue.contentChanged()
            }
        }
    }

    /// 离最新处多远、一屏多高（取整：亚像素的抖动不触发更新）。
    private struct Reading: Equatable {
        var distance: CGFloat
        var screen: CGFloat
        /// 滚到最新处的偏移（正着排时）。
        var end: CGFloat
    }

    private func toNewest() {
        if reduceMotion {
            position.scrollTo(edge: Self.newestEdge)
        } else {
            withAnimation(Motion.quick) { position.scrollTo(edge: Self.newestEdge) }
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

#if os(iOS)
private extension View {
    /// 把滚动区倒过来。转 180° 而不是上下镜像：镜像（行列式为负）时系统长按预览截到的是空白；代价是滚动条转到了左边，所以藏起来。
    /// 不裁内容：对话一直滚到顶栏、回复框与键盘后面，上下都不淡出（系统的滚动边缘效果由 `RouteView` 全关；它按没转过的方向画，
    /// 开着时滚动区尺寸一变会把整片对话糊成一帧模糊）。
    /// 滚动区自己的设定（挂在 ScrollView 上，`tracked` 再把它包进量宽的一层）。
    func newestFirstScroll() -> some View {
        scrollIndicators(.hidden)
            .scrollClipDisabled()
            .defaultScrollAnchor(.top)
    }

    func newestFirst() -> some View {
        rotationEffect(.degrees(180))
            .environment(\.chatInverted, true)
    }
}
#endif
