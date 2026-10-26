import SwiftUI

/// 贴着最新（规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底，回到最新处（自己滚回、点"回到最新"）重新贴上；
/// 输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。离最新处超过一屏出"回到最新"圆钮（离开后来了新内容时带的点在 `ChatScroll`）。
/// 顶栏让开（`showsHeader`，iPhone 与 Mac 同一条）：离开最新就让开，看历史期间怎么滑都不出现（往回滑也不出来，
/// 免得读的时候顶栏一闪一闪）；点它原来的位置唤出（`reveal`），再滑又让开；回到最新（滑到底、点"回到最新"、发出消息）自动出现。
/// 平台不同的只有"⋯"：iPhone 上跟标题一起让开（顶栏浮在对话上，少一颗圆钮就少一块遮挡，`floatingHeader` 的 `hidden`）；
/// Mac 上只让开标题、"⋯"一直在——Mac 没有状态栏，工具栏本来就一直在，让开只在那组玻璃里留下一格空位。iPhone 的返回钮不在这条规则里，
/// 一直在：看历史时也看得到怎么回去（Mac 没有返回钮，导航在侧栏）。
nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    /// 离最新处超过一屏：出"回到最新"圆钮。
    private(set) var showsJump = false
    /// 可见区顶边离最早那头不到一屏。
    private(set) var nearOldest = false
    /// 正在上面排开更早的一段：排上去之前不再要下一批（`wantsEarlier`）。排上去时正在读的不动由滚动区按那一条补（`ChatAnchor`），
    /// 它按补后的位置报离最早那头还近不近（`prepended`）。
    private(set) var prepending = false
    /// 请滚动区回到最新（`jumpToNewest`、`sent`）：滚动区看到它变了就滚过去。
    private(set) var toNewest: ToNewest?
    /// 请滚动区跳到的那一条（`jump(to:)`），你自己滚或回到最新时放掉：在这之前上面排开了一段，滚动区按它重新对准，
    /// 它所在的段排真的（`chatTarget`）。
    private(set) var target: Target?
    /// 请对话把某一条排开、描圈再跳过去（`seek`）：对话（`SessionChat`）看到它变了就照做。
    private(set) var seeking: Target?
    /// 用户正拖着或甩着滚动区（滚动区写入）。刚开始滚时人已经离开了最新处（读数先到）就在这里解除贴底。
    var scrolling = false {
        didSet {
            if scrolling {
                jumping = false
                target = nil
            }
            if scrolling, !withinSlack {
                atNewest = false
                revealed = false
            }
        }
    }
    /// 已请滚动区跳到某一条（`jump(to:)`）、还没离开最新处：跳的那一下顶栏让开、回复框收起，滚动区排好了下一帧才滚过去，
    /// 这期间的读数还报着在最新处，不算回到了最新。离开最新处（跳过去了）、用户自己滚、回到最新时放掉；跳到的就在最新处时，用户一滚就重新贴上。
    private var jumping = false
    private var withinSlack = true
    /// 在看历史时点顶部唤出了顶栏。
    private var revealed = false
    /// 离最新处这么近算"在最新处"。
    static let slack: CGFloat = 24

    /// 离最早那头不到一屏、上一批也排上去了：对话在上面再排开一批（`ChatColumn`）。
    var wantsEarlier: Bool { nearOldest && !prepending }

    /// 标题此刻露着（iPhone 的"⋯"跟着它；返回钮与 Mac 的"⋯"一直在，见上）。
    var showsHeader: Bool { atNewest || revealed }

    struct Target: Equatable {
        let id: UUID
        var landing = Landing.flash
        let request = UUID()

        var anchor: UnitPoint { landing == .read ? .top : .center }
    }

    /// 跳到的那一条停在哪：描一圈、停在可见区中间（刻度滑条、经过清单、批注），或从它读起、停在顶上（Cue 页的新消息，
    /// 下面不到一屏时滚动区停在最新处）。从它读起是打开时就在那儿，不滑过去：不是你要跳的，看到一段滑动是多余的。
    enum Landing { case flash, read }

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
        if !near { jumping = false }
        if near, !jumping {
            atNewest = true
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

    mutating func jumpToNewest() { returnToNewest(sent: false) }

    mutating func sent() { returnToNewest(sent: true) }

    /// 要回到最新当场就贴上，不等滚到了读数来报：滚动区这时就按贴底排（内容变高矮时底锚、不跟正在读的那一条，`ChatScroll`）。
    /// 等读数的话，这之间到的内容（发出的那句、答掉的拍板回到对话里）按"正在读的不动"排，可见区被留在上面、发出的那句压在输入框下；
    /// 从新消息读起（`Landing.read`）落在最新处时读数不再变，一直等不到。
    private mutating func returnToNewest(sent: Bool) {
        atNewest = true
        revealed = false
        jumping = false
        target = nil
        toNewest = ToNewest(sent: sent)
    }

    mutating func willPrepend() { prepending = true }

    /// 排上去的那一批到了、偏移补好了；`nearOldest` 是补好之后可见区离最早那头还近不近（`ChatScroll` 按补的量算）。
    mutating func prepended(nearOldest: Bool) {
        prepending = false
        self.nearOldest = nearOldest
    }

    /// 去读某一条（刻度滑条、回复框上的批注）：它可能还没排开，先由对话排开再 `jump(to:)`。
    mutating func seek(_ id: UUID, landing: Landing = .flash) { seeking = Target(id: id, landing: landing) }

    /// 跳到某一条去读：不再贴着最新。
    mutating func jump(to target: Target) {
        atNewest = false
        revealed = false
        jumping = true
        self.target = target
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

nonisolated enum ChatLayout {
    /// 对话最新那头与最早那头的留白：最后一行离回复框（含问题卡）至少这么远。
    static let edge: CGFloat = 16
    /// 浮在对话底上的那一块离对话区底边（手机上是安全区底边，键盘弹出时是键盘顶，`FloatingReply`）。
    static let replyGap: CGFloat = 8

    /// 阅读栏两边的边距：窄时是 `inset`，宽时把栏居中。滚动区（`ChatScroll`）与叠在对话区上的空态（`BlankChat`）共用。
    static func margin(_ width: CGFloat, readingWidth: CGFloat, inset: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }
}

extension EnvironmentValues {
    /// 刚跳到的那条你的话：短暂描一圈（刻度滑条）。
    @Entry var chatHighlight: UUID?
    /// 要跳去的那一条（`ChatColumn` 给，描不描圈都算，`ChatFollow.target`）：它所在的段排真的（`ChatSegments`），跳过去时找得到它。
    @Entry var chatTarget: UUID?
    /// 跳到对话里的某一条去读（`ChatColumn` 给）：经过清单里"对你说"那一条点它回到原处。不在对话区里为 nil。
    @Entry var chatJump: ChatJump?
    /// 浮在对话底上的那一块占的高（`FloatingReply`：Mac 的回复框，手机 Cue 页的拍板卡与输入框）：对话在底下让出这么高，最新一行停在它上方。
    @Entry var chatBottomInset: CGFloat = 0
    /// 对话区可见的高（`FloatingReply` 给浮在底上的那一块）：拍板卡至多占它一半。
    @Entry var chatHeight: CGFloat = .infinity
    /// 阅读栏两边的页边距（`ChatLayout.margin`，`ChatColumn` 按可见区的宽算一次）：边上放的小东西（刻度、新消息的点）据它看放不放得下。
    @Entry var chatMargin: CGFloat = 0
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
                .glass(in: .circle, interactive: true, ink: .clear)
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
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(unseen ? "回到最新，有新内容" : "回到最新")
    }
}
