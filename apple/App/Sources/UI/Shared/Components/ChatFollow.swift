import SwiftUI

/// 贴着最新（规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底；输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。
/// 看历史期间顶栏怎么滑都不出现（往回滑也不出来，免得读的时候顶栏一闪一闪）。
/// 平台不同的只有"⋯"：iPhone 上返回、标题、"⋯"整排一起让开（顶栏浮在对话上，整排让开读的时候顶上一块遮挡都没有，左缘右滑照样返回，`floatingHeader` 的 `hidden`）；Mac 上只让开标题、"⋯"一直在——Mac 没有状态栏，工具栏本来就一直在，让开只在那组玻璃里留下一格空位（Mac 没有返回钮，导航在侧栏）。
nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    private(set) var showsJump = false
    private(set) var nearOldest = false
    /// 排上去之前不再要下一批（`wantsEarlier`）；排上去时正在读的不动，由滚动区按那一条补（`ChatAnchor`），它按补后的位置报离最早那头还近不近（`prepended`）。
    private(set) var prepending = false
    private(set) var toNewest: ToNewest?
    /// 你自己滚或回到最新时放掉；在这之前上面排开了一段，滚动区按它重新对准，它所在的段排真的（`chatTarget`）。
    private(set) var target: Target?
    private(set) var seeking: Target?
    /// 开始看时欠着的一次从第一条新消息读起（Cue 页，`CueViewing`）：正在和 iCloud 对时等对完才落。这之间你自己滚、回到最新、
    /// 发出一句、跳去某一条，就是已经在看了，不再落：对完时不把你从刚发出的那句带走，一拉翻几页时也不每对完一次落一回。
    private(set) var owesLanding = false
    /// 刚开始滚时人已经离开了最新处（读数先到）就在这里解除贴底。
    var scrolling = false {
        didSet {
            if scrolling {
                jumping = false
                staying = false
                target = nil
                owesLanding = false
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
    private var staying = false
    private var withinSlack = true
    private var revealed = false
    static let slack: CGFloat = 24

    var wantsEarlier: Bool { nearOldest && !prepending }

    var showsHeader: Bool { atNewest || revealed }

    struct Target: Equatable {
        let id: UUID
        var landing = Landing.flash
        let request = UUID()

        var anchor: UnitPoint { landing == .read ? .top : .center }
    }

    /// 从它读起（Cue 页的新消息）是打开时就在那儿，不滑过去：不是你要跳的，看到一段滑动是多余的。
    enum Landing { case flash, read }

    struct ToNewest: Equatable {
        /// 因为发出了一句：回复框随即收起，它让出的地方由滚动区留到这句到了再收（`ChatScroll`）。
        let sent: Bool
        let request = UUID()
    }

    /// 读数是每帧都变的，状态不能跟着每帧写，所以滚动区只在离最新处不超过 `slack`、超过一屏、离最早处不到一屏这三条越线时才来报（`ChatScroll`）；`byUser`：是用户拖着或甩着带来的。
    mutating func scrolled(atNewest near: Bool, beyondScreen: Bool, nearOldest: Bool, byUser: Bool) {
        showsJump = beyondScreen
        self.nearOldest = nearOldest
        withinSlack = near
        if !near { jumping = false }
        if near, !jumping, !staying {
            atNewest = true
            revealed = false
        } else if byUser {
            atNewest = false
            revealed = false
        }
    }

    /// 你点开了对话里的一块（一轮的经过、其中一步）：贴着最新时内容变高是往上顶的，点的那一行会被顶出屏幕。
    /// 所以点开时和你自己滚走一样解除贴底，它往下长、点的那一行不动；顶栏留着（你没去看历史）。
    /// 开着的期间读数报着在最新处也不贴回去（长出来的可能还没把最新处推远：先长出一行"正在取"、取到了才长出整块）；
    /// 收起、你自己滚、回到最新时放掉，读数报回在最新处就重新贴上。
    mutating func stay(_ open: Bool) {
        if open, atNewest {
            atNewest = false
            revealed = true
        }
        staying = open
    }

    mutating func reveal() {
        if !atNewest { revealed = true }
    }

    mutating func jumpToNewest() { returnToNewest(sent: false) }

    mutating func sent() { returnToNewest(sent: true) }

    /// 要回到最新当场就贴上，不等滚到了读数来报：滚动区这时就按贴底排（内容变高矮时底锚、不跟正在读的那一条，`ChatScroll`）。
    /// 等读数的话，这之间到的内容（发出的那句、答掉的拍板回到对话里）按"正在读的不动"排，可见区被留在上面、发出的那句压在输入框下；
    /// 从新消息读起（`Landing.read`）落在最新处时读数不再变，一直等不到。
    private mutating func returnToNewest(sent: Bool) {
        owesLanding = false
        atNewest = true
        revealed = false
        jumping = false
        staying = false
        target = nil
        toNewest = ToNewest(sent: sent)
    }

    mutating func willPrepend() { prepending = true }

    mutating func prepended(nearOldest: Bool) {
        prepending = false
        self.nearOldest = nearOldest
    }

    mutating func seek(_ id: UUID, landing: Landing = .flash) {
        owesLanding = false
        seeking = Target(id: id, landing: landing)
    }

    mutating func oweLanding() { owesLanding = true }

    mutating func land(on first: UUID?) {
        guard owesLanding else { return }
        owesLanding = false
        if let first { seeking = Target(id: first, landing: .read) }
    }

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

/// 点开对话里的一块时叫它（`ChatFollow.stay`）；比较的规则同 `ChatJump`。
struct ChatStay: Equatable {
    let column: UUID
    let stay: (Bool) -> Void

    func callAsFunction(_ open: Bool) { stay(open) }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.column == b.column }
}

nonisolated enum ChatLayout {
    static let edge: CGFloat = 16

    static func margin(_ width: CGFloat, readingWidth: CGFloat, inset: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }
}

extension EnvironmentValues {
    @Entry var chatHighlight: UUID?
    @Entry var chatTarget: UUID?
    @Entry var chatJump: ChatJump?
    @Entry var chatStay: ChatStay?
    @Entry var chatBottomInset: CGFloat = 0
    @Entry var chatHeight: CGFloat = .infinity
    @Entry var chatMargin: CGFloat = 0
}

struct JumpToNewest: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 44
    static let inset: CGFloat = 10
    static var clearance: CGFloat { size + 2 * inset }

    var body: some View {
        Button(action: action) {
            Image(.toLatest).font(Glyph.control.weight(.semibold)).foregroundStyle(palette.ink)
                .frame(width: 40, height: 40)
                .glass(in: .circle, interactive: true, ink: .clear)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        StatusDot(color: palette.ink, rim: palette.desk)
                            .offset(x: -3, y: 3)
                            .transition(Motion.pop(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(unseen ? "回到最新，有新内容" : "回到最新")
    }
}
