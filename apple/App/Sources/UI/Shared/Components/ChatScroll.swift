import Synchronization
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
    /// 请滚动区回到最新（`jumpToNewest`、`sent`）：滚动区看到它变了就滚过去。
    private(set) var toNewest: ToNewest?
    /// 请滚动区跳到的那一条（`jump(to:)`）。
    private(set) var target: Target?
    /// 请对话把某一条排开、描圈再跳过去（`seek`）：对话（`SessionChat`）看到它变了就照做。
    private(set) var seeking: Target?
    /// 用户正拖着或甩着滚动区（滚动区写入）。刚开始滚时人已经离开了最新处（读数先到）就在这里解除贴底。
    var scrolling = false {
        didSet {
            if scrolling, !withinSlack {
                atNewest = false
                revealed = false
            }
        }
    }
    /// 最近一次读数里离最新处不超过 `slack`。
    private var withinSlack = true
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

    struct ToNewest: Equatable {
        /// 因为发出了一句：回复框随即收起，它让出的地方由滚动区留到这句到了再收（`ChatScroll`）。
        let sent: Bool
        let request = UUID()
    }

    /// 滚动区此刻的位置，只说够不够近：离最新处不超过 `slack`、超过一屏，离最早处不到一屏。读数是每帧都变的，状态不能跟着每帧写，
    /// 所以滚动区只在这三条越线时才来报（`ChatScroll`）；`byUser`：是用户拖着或甩着带来的。
    mutating func scrolled(atNewest near: Bool, beyondScreen: Bool, nearOldest: Bool, byUser: Bool) {
        showsJump = beyondScreen
        self.nearOldest = nearOldest
        withinSlack = near
        if near {
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

    mutating func jumpToNewest() { toNewest = ToNewest(sent: false) }

    mutating func sent() { toNewest = ToNewest(sent: true) }

    mutating func willPrepend() { prepending = true }

    mutating func prepended() { prepending = false }

    /// 去读某一条（刻度滑条、回复框上的批注）：它可能还没排开，先由对话排开再 `jump(to:)`。
    mutating func seek(_ id: UUID) { seeking = Target(id: id) }

    /// 跳到某一条去读：不再贴着最新（跳到的就在最新处时，滚到后会重新贴上）。
    mutating func jump(to id: UUID) {
        atNewest = false
        revealed = false
        target = Target(id: id)
    }
}

/// 跳到对话里的某一条（`chatJump`）。按所在的对话区比较：同一个对话区每次更新换出的闭包做的是同一件事（改的是同一个 `ChatFollow`），
/// 读它的行（每轮的经过）不因换了一个闭包跟着重算；闭包本身不能比较，直接放进环境时每次更新都让读它的视图失效。
struct ChatJump: Equatable {
    let column: UUID
    let seek: (UUID) -> Void

    func callAsFunction(_ id: UUID) { seek(id) }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.column == b.column }
}

enum ChatLayout {
    /// 对话最新那头与最早那头的留白：最后一行离回复框（含排队、问题卡）至少这么远。
    static let edge: CGFloat = 16
}

extension EnvironmentValues {
    /// 刚跳到的那条你的话：短暂描一圈（刻度滑条）。
    @Entry var chatHighlight: UUID?
    /// 跳到对话里的某一条去读（`ChatColumn` 给）：经过清单里"对你说"那一条点它回到原处。不在对话区里为 nil。
    @Entry var chatJump: ChatJump?
    /// 浮在对话底上的回复框占的高（Mac，`FloatingReply`）：对话在底下让出这么高，最新一行停在它上方。
    @Entry var chatBottomInset: CGFloat = 0
}

/// 聊天式的滚动区（会话页与 Cue 页、Mac 与 iPhone 共用，经 `ChatColumn`）：打开停在最新，贴着最新时跟着新内容与底下输入框的长高、键盘的弹出，
/// 用户滚走后这些都不再挪动正在读的内容；离最新处超过一屏时可见区右下角（回复框右上方）浮出圆形"回到最新"，
/// 离开后来过新内容时带一个点，点它回到最新（`ChatFollow`）。`followKey` 变了就算有新内容。
/// 贴着最新时新内容在下面长出来，整段滑上去，不一下顶上去；发出一句时回复框让出的地方先留着，那句到了一起收（`bottomPadding`），
/// 收起回复框、新的一条出现、对话上移是同一段滑动。减弱动态效果下滚动不做动画。
/// 本机正在和 iCloud 对（`holding`，回到前台、刚打开时拉到的积压一页页地到）时，贴着最新也先不跟：新的长在可见区下面、看着的不动，
/// 对完再一次滑上来——一页一滑的话整段对话一路往下闪。自己发出一句、点"回到最新"照常立刻去。
///
/// 对话不用懒加载栈、只排最近几条（`PiConversation` 的窗口）：懒加载栈的总高与偏移都是按估计高度推出来的，回答高矮悬殊时
/// 底部锚定会落在内容外、整页空白（WWDC26「Dive into lazy stacks」也说绝对偏移不可靠）；整段排开位置是确定的，
/// 打开时的底部锚点就是最新处。往上翻快到头时在上面再排开一段，多出来的高度加到偏移上，正在读的不动（`ChatFollow.prepending`）。
/// 滚动区铺到顶栏、状态栏与回复框后面（iOS 的栏与键盘是安全区，滚动区把它当内容边距），内容在玻璃后面清楚可见。
///
/// 对话排在阅读栏里：最宽 `readingWidth`（含左右 `inset`），在滚动区里居中，上下各留 `edge`。栏的边距只能是滚动区的
/// 内容边距（`contentMargins`），不能是内容外面的 padding 或居中的框：滚动位置跟着一行（滚动目标）走，内容变了就把那一行
/// 对回可见区的左上角——行若离内容原点有一段边距，整段对话就被横着推出那一段。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    private let readingWidth: CGFloat
    private let inset: CGFloat
    /// 贴底与否、请求跳到哪：由放它的页面持有（页面据它收起顶栏、输入框）。
    private let follow: Binding<ChatFollow>
    private let holding: Bool
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatBottomInset) private var bottomInset
    /// 不从"贴着底边"起：那样内容一变高滚动区自己就一下跳到新的底（打开时停在最新处由 `initialOffset` 的底锚管）。
    @State private var position = ScrollPosition()
    @State private var offset = ScrollOffset()
    /// 发出那一刻浮着的回复框的高（`toNewest`、`bottomPadding`），发出的话到了（内容在下面长高）就放掉。
    @State private var held: CGFloat?
    /// `holding` 期间内容在下面长了、还没滑上去。
    @State private var deferred = false
    /// `holding` 期间自己要回到最新（发出一句、点圆钮）：这一次对完之前照常跟着。
    @State private var unheld = false

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, holding: Bool = false, @ViewBuilder content: () -> Content
    ) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        self.holding = holding
        self.follow = follow
        self.content = content()
    }

    /// 阅读栏两边的边距：窄时是 `inset`，宽时把栏居中。
    private func margin(_ width: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }

    /// 内容底下让出浮着的回复框（Mac，`chatBottomInset`）的留白。发出时回复框当下收起，发出的话要等写进库才到：那之前留白不跟着变矮，
    /// 那句到了（内容真的长高）再收，对话从回复框让出的地方滑上去；跟着变矮的话贴着最新的整段对话先被拉下来一两帧，再一下顶上去。
    /// 看内容长高，不看 `followKey`：它还算着别的（之前那句的送达情况），可能比那句先变。
    /// 排在内容里而不是内容边距：Mac 的滚动区改边距要晚一次排版才生效，那时它自己把偏移一下挪到底，就滑不起来了。
    /// iPhone 的回复框是安全区、平时为 0：发出时键盘随即收起，对话跟着键盘的动画走，不留。
    private var bottomPadding: CGFloat { max(bottomInset, held ?? 0) }

    var body: some View {
        // 边距按滚动区的宽在同一次排版里定（GeometryReader 先拿到自己的尺寸再排里面），不写回状态：
        // 宽屏（iPad、Mac 宽窗口）首帧就是居中的栏，不会先按窄边距排一帧再挪
        GeometryReader { proxy in
            let padding = bottomPadding
            ScrollView { content.padding(.bottom, padding) }
                // 只管打开时停在最新处、不满一屏时贴底。内容变高时不靠底锚：它一下跳到新的底，新来的那条没法滑上来（贴着最新由读数补滚）
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                // 栏贴着滚动区两边（手机、窄窗口）时，横向滚动的表格可以越过页边距滑到边上（`readingColumnBleeds`）
                .environment(\.readingColumnBleeds, proxy.size.width <= readingWidth)
                .contentMargins(.horizontal, margin(proxy.size.width), for: .scrollContent)
                .contentMargins(.vertical, ChatLayout.edge, for: .scrollContent)
                .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
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
                    let end = (geometry.contentSize.height - geometry.containerSize.height).rounded()
                    offset.set(read: max(0, read.rounded()), end: end)
                    return Reading(
                        nearNewest: distance <= ChatFollow.slack, beyondScreen: distance > screen, nearOldest: read < screen,
                        height: (geometry.contentSize.height - padding).rounded(), end: end, inset: geometry.contentInsets.top.rounded())
                } action: { previous, reading in
                    let last = offset.deliver(reading) ?? previous
                    let grown = reading.height - last.height
                    if follow.wrappedValue.prepending, grown > 0 {
                        follow.wrappedValue.prepended()
                        position.scrollTo(y: offset.read + grown)
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
                    if holding, !unheld, grown > 0, reading.inset == last.inset {
                        deferred = true
                        return
                    }
                    // 新内容、正在说的话在下面长出来：整段滑上去（滑到留白收起后的最新处）。回复框长高、键盘弹出、栏的高度第一次加进内容边距
                    // （这一下系统把偏移放回顶上），最新处变远了：直接补滚过去。在读数里补（布局定下来之后）。滚动区变矮时读数已报在底、
                    // 画面与点按却还停在原处（Mac 打开会话时回复框比占位高，最后一行压在回复框下、选不中），所以看最新处远没远，不看在不在底；
                    // 最新处变近了滚动区自己会退回来
                    if grown > 0, reading.inset == last.inset {
                        slide()
                    } else if reading.end > last.end || reading.inset != last.inset {
                        scroll(to: reading.end)
                    }
                }
                .onChange(of: followKey) { follow.wrappedValue.contentChanged() }
                .onChange(of: holding) {
                    unheld = false
                    guard !holding, deferred else { return }
                    deferred = false
                    slide()
                }
        }
        .overlay(alignment: .bottomTrailing) {
            if follow.wrappedValue.showsJump {
                JumpToNewest(unseen: follow.wrappedValue.hasUnseen) { follow.wrappedValue.jumpToNewest() }
                    .padding(.trailing, JumpToNewest.inset).padding(.bottom, JumpToNewest.inset + bottomInset)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: follow.wrappedValue.showsJump)
        .animation(Motion.quick, value: follow.wrappedValue.hasUnseen)
        .onChange(of: follow.wrappedValue.toNewest) { _, request in if let request { toNewest(sent: request.sent) } }
        .onChange(of: follow.wrappedValue.target) { _, target in
            guard let target else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { position.scrollTo(id: target.id, anchor: .center) }
        }
    }

    /// 最近一次读数（偏移、最新处）与上一次交给读数 action 的读数。读数闭包不一定在主线程，所以带锁；
    /// 它不是状态，写它不触发任何更新。
    private final class ScrollOffset: Sendable {
        private struct Values {
            /// 可见区顶边在内容里的位置。内容在下面或上面变高时滚动区不挪偏移，它就是变高之前的位置（往上排开一段时据它补高度差，`ChatFollow.prepending`）。
            var read: CGFloat = 0
            /// 最新处的偏移（`scrollTo(y:)` 的 y）。
            var end: CGFloat = 0
            /// 上一次交给 action 的读数。不用 action 给的旧值：那是上一次求值，中间几次变化（打开时排开更早的一段）可能求了值却没调 action，
            /// 拿它比内容变没变高会漏掉。
            var delivered: Reading?
            /// 补滚换着用的两种写法（`scroll(to:)`）：这一次用不用"滚到那一点"。
            var byPoint = false
        }

        private let values = Mutex(Values())

        func set(read: CGFloat, end: CGFloat) {
            values.withLock {
                $0.read = read
                $0.end = end
            }
        }

        var read: CGFloat { values.withLock { $0.read } }
        var end: CGFloat { values.withLock { $0.end } }

        /// 换上这次交给 action 的读数，返回上一次交过去的。
        func deliver(_ reading: Reading) -> Reading? {
            values.withLock { values in
                defer { values.delivered = reading }
                return values.delivered
            }
        }

        func flip() -> Bool { values.withLock { $0.byPoint.toggle(); return $0.byPoint } }
    }

    /// 滚动区的读数：只留下会让状态改变的几条越线（离最新处近不近、超没超一屏、离最早处近不近）与内容高、边距，每帧都变的偏移不进来。
    /// `action` 只在读数变了才跑，滚动时每帧不碰页面的状态。
    private struct Reading: Equatable {
        var nearNewest: Bool
        var beyondScreen: Bool
        var nearOldest: Bool
        /// 内容的高，不含让出回复框的那段（它变高变矮是回复框的事，不滑）。
        var height: CGFloat
        /// 滚到最新处时可见区顶边在内容里的位置（`scrollTo(y:)` 的 y，不含内容边距）。
        var end: CGFloat
        /// 顶部的内容边距：它一变系统就把偏移放回顶上，读数要跟着变，才会再补滚一次。
        var inset: CGFloat
    }

    /// 内容在下面长出来了，整段滑到最新处（减弱动态效果时直接到）。用定长的 `Motion.move`，不用弹簧：弹簧最后那段一两像素的尾巴
    /// 要再画两百多毫秒，正好压在发出的话送达、状态变了的那几次更新上，那几帧本来不用画，一画就掉帧。
    /// 等长出来的这一帧提交了再滑：这一帧要排出新的一条，排版重；动画从这一帧起算的话，第一帧画出来时已经走了一大截，看着是一跳。
    /// 滑到的是那时的最新处（留白收起之后）；等的这一帧里用户开始滚了就不滑了。
    private func slide() {
        Task {
            await NextFrame.wait()
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling else { return }
            withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) { scroll(to: offset.end) }
        }
    }

    /// 回到最新（点圆钮、发出一句）。发出时记下回复框此刻的高（`bottomPadding`）。已经在最新处就不用滚。
    private func toNewest(sent: Bool) {
        held = sent ? bottomInset : nil
        if holding { unheld = true }
        // 对的期间报着"在最新处"，下面其实还压着没滑上来的
        guard !follow.wrappedValue.atNewest || deferred else { return }
        deferred = false
        withAnimation(reduceMotion ? nil : Motion.quick) { scroll(to: offset.end) }
    }

    /// 滚到偏移 `y`。不滚到底边：停在底边时内容一变高，滚动区自己就一下跳过去了。同一个请求再发一次时滚动位置的值不变、滚动区不动
    /// （偏移被内容边距的变化挪走、用户又没碰过时就是这样），所以在"滚到 y"与"滚到 (0, y)"两种等价的写法之间换着发。
    private func scroll(to y: CGFloat) {
        if offset.flip() { position.scrollTo(point: CGPoint(x: 0, y: y)) } else { position.scrollTo(y: y) }
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
            Image(.toLatest).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                .frame(width: 40, height: 40)
                .glass(in: .circle, interactive: true)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(palette.ink).frame(width: 10, height: 10)
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
