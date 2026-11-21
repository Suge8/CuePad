import SwiftUI

/// 只由窗口宽、用户的两个开合选择（会话条 `AppSettings.railExpanded`、Cue `cueOpen`）与主区并排了哪几块推出，不看主区放着什么页：换页时栏不动。
/// Cue 铺满时（`home`）没有主区：会话条之外全是它。
/// 自动收起只改呈现、不改选择：选了开着、窗口放不下时照样藏起，放得下了回到所选（HIG「Sidebars」：窗口变小时自动藏起侧栏，同邮件）。
/// 窗口变窄时先把 Cue 收成钮，再藏起会话条：会话条是换去处的地方，点它的一行不该让它自己消失；Cue 收着时一下就回得去（它那一行、右上的钮）。
/// 主区最窄是并排的几块各自最窄之和：并排是用户自己开的，栏跟着让位读得出原因。连会话条也藏起仍放不下的，最右的几块不画（还在导航里，拉宽了回来）。
/// 并排开着（右边有块）时 Cue 收成钮（同样只改呈现，`cueOpen` 不动，收起并排就回到所选）：主区是正在干的活、先拿宽，
/// Cue 是总控、有余地才占一栏，在钮里一下就回得去；收起与右边滑出是同一次换形（`shape`），同一段滑动。
/// 块与块之间的分界可拖（`Shares`），每种摆法（右边各块是什么）各记一份比例；每块不窄于自己的最窄（`Kind.narrowest`）。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    /// Mac 的含浮板四周那一圈（`CueColumn.float`）：板本身 372，名牌（`CueTitle.width`）连收起钮放得下四项数字账。
    #if os(macOS)
    static let cue: CGFloat = 388
    #else
    static let cue: CGFloat = 400
    #endif

    /// 活预览最窄：手机宽那一档连两侧留白放得下。
    static let previewWidth = LivePreview.phoneWidth + 2 * Spacing.page

    /// 主区里一块是什么，只管它的宽：最窄与默认分到的份量（看网页要比看对话宽，预览默认多分一半）。
    enum Kind: Hashable {
        case session, preview, card

        init(_ pane: WideNavigation.Beside) {
            switch pane {
            case .session: self = .session
            case .preview: self = .preview
            case .card: self = .card
            }
        }

        var narrowest: CGFloat { self == .preview ? WideMetrics.previewWidth : WideMetrics.session }
        var weight: CGFloat { self == .preview ? 1.5 : 1 }
    }

    /// 分界拖到了哪（每个窗口一份，`Workspace.paneShares`）：按右边各块是什么各记一份几块各占主区的几成，没拖过的按份量分。
    struct Shares: Equatable {
        private var stored: [[Kind]: [CGFloat]] = [:]

        func fractions(_ beside: [Kind]) -> [CGFloat] {
            if let kept = stored[beside] { return kept }
            let weights = [Kind.session.weight] + beside.map(\.weight)
            let total = weights.reduce(0, +)
            return weights.map { $0 / total }
        }

        mutating func set(_ fractions: [CGFloat]?, for beside: [Kind]) { stored[beside] = fractions }
    }

    let home: Bool
    let rail: CGFloat
    let railFits: Bool
    let main: CGFloat
    let cue: CGFloat
    /// 右边此刻画出来的几块（`Workspace.beside` 的前几块）。
    let beside: [Kind]
    /// 主区几块的宽，从左到右；不并排时只有一块（整个主区）。
    let widths: [CGFloat]
    /// 活预览放大到整个窗口（`Workspace.liveFill`）：会话条收起，预览那一块盖过主区。
    let fill: Bool
    let cueFits: Bool
    /// 这个窗口放得下几块：画出来的几块，加上余下的宽还放得下几个最窄的会话（`session`）。同画不画按同一条宽算（会话条放不下就藏），
    /// 开在旁边、拖进来插一块时多出的挤掉最右那块（`Workspace.wideRoom`）。
    let room: Int
    /// 主区从左到右放着的几块里画出来的那些（最左不是会话时为空）：块按它认，挪了位置的从旧处滑到新处（`WideColumnSlide`）。
    let order: [WideNavigation.Beside]

    var split: Bool { !beside.isEmpty }
    func narrowest(_ index: Int) -> CGFloat { index == 0 ? Self.session : beside[index - 1].narrowest }
    var leading: CGFloat { widths[0] }

    /// 第 `index` 块（0 是最左）的左缘离窗口左缘多远；没画出来的停在窗口右缘外（`width` 是窗口宽）。
    func origin(_ index: Int, window: CGFloat) -> CGFloat {
        guard index < widths.count else { return window }
        guard index > 0 else { return rail }
        if fill { return beside[index - 1] == .preview ? 0 : window }
        return edge(after: index - 1)
    }

    /// 第 `index` 块与右边那块的分界离窗口左缘多远。
    func edge(after index: Int) -> CGFloat { rail + widths.prefix(index + 1).reduce(0, +) }

    /// 第 `index` 块的宽；没画出来的是此刻开出它会有的宽，停在窗口右缘外（几块一直挂着，`MainWindow.beside`、`SplitRoot.beside`）。
    func width(_ index: Int) -> CGFloat {
        guard index < widths.count else { return (main / 2).rounded() }
        return fill && index > 0 ? main : widths[index]
    }

    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
        var panes = 1
        var fill = false
        var order: [WideNavigation.Beside] = []
    }

    /// 铺满的 Cue 随窗口变宽，不算换了形：拖窗口时不起滑动。
    /// 并排添一块、收一块、几块换了位置也算换形：添的那一块从主区右缘长出来、收回去（`MainWindow`、`SplitRoot` 一直挂着它），挪了的从旧处滑过去。
    var shape: Shape { Shape(rail: rail, cue: home ? -1 : cue, panes: widths.count, fill: fill, order: order) }

    /// 主区里画出来的每一块在窗口里的左缘与宽。
    var spans: [WideNavigation.Beside: Span] {
        Dictionary(order.indices.map { (order[$0], Span(origin: origin($0, window: .infinity), width: width($0))) }) { first, _ in first }
    }

    struct Span: Equatable {
        let origin: CGFloat
        let width: CGFloat
    }

    /// `width` 是窗口宽：放得下几块、画出来几块随导航变，由工作区按它当场算（`Workspace.wideSizes`），不存上一次排版的结果。
    struct Fits: Equatable {
        let rail: Bool
        let cue: Bool
        let width: CGFloat
    }

    let window: CGFloat
    var fits: Fits { Fits(rail: railFits, cue: cueFits, width: window) }

    /// `navigation` 给了就按它排（拖着时预演放下后的样子，`WideDropFeedback`），否则按工作区此刻的。
    init(width: CGFloat, workspace: Workspace, navigation: WideNavigation? = nil) {
        window = width
        home = navigation?.home ?? workspace.cueHome
        let panes = home ? [] : navigation?.panes ?? workspace.session(in: .main).map { [.session($0)] + workspace.beside } ?? []
        let wanted = panes.dropFirst().map(Kind.init)
        var shown = wanted.count
        while shown > 0, Self.session + wanted.prefix(shown).map(\.narrowest).reduce(0, +) > width { shown -= 1 }
        beside = Array(wanted.prefix(shown))
        order = Array(panes.prefix(1 + shown))
        fill = beside.contains(.preview) && workspace.liveFill != nil
        let narrowest = Self.session + beside.map(\.narrowest).reduce(0, +)
        railFits = width >= Chrome.rail + narrowest
        rail = workspace.sidebarOpen && railFits && !fill ? Chrome.rail : 0
        cueFits = home || beside.isEmpty && width >= rail + narrowest + Self.cue
        cue = home ? width - rail : workspace.services.settings.cueOpen && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
        widths = Self.widths(main: main, beside: beside, fractions: workspace.paneShares.fractions(beside))
        let spare = max(0, width - narrowest)
        room = min(WideNavigation.maxPanes, 1 + shown + Int(spare / Self.session))
    }

    /// 按几成分主区，再让每块不窄于自己的最窄：超出的从最右那块往左收回（先保左边）；主区连最窄之和都放不下时左边那块仍保 `session`，右边的挤。
    static func widths(main: CGFloat, beside: [Kind], fractions: [CGFloat]) -> [CGFloat] {
        let narrowest = [session] + beside.map(\.narrowest)
        var widths = zip(fractions, narrowest).map { max($1, ($0 * main).rounded()) }
        var excess = widths.reduce(0, +) - main
        for index in widths.indices.reversed() where excess > 0 {
            let give = min(excess, widths[index] - narrowest[index])
            widths[index] -= give
            excess -= give
        }
        for index in widths.indices.dropFirst().reversed() where excess > 0 {
            let give = min(excess, widths[index])
            widths[index] -= give
            excess -= give
        }
        widths[widths.count - 1] += max(0, main - widths.reduce(0, +))
        return widths
    }

    /// 宽屏看板"列头就是最顶那一排、范围钮在开头"：列让出栏头左边与那颗钮，卡片自带的那一圈不算。
    static func boardLead(_ inset: EdgeInsets) -> CGFloat { inset.leading + Spacing.item + Chrome.control - BoardCardMetrics.inset }

    static func narrowestMain(split: Bool) -> CGFloat { split ? 2 * session : session }

    /// 会话条放得下的最窄窗口；Cue 在会话条开着时放得下的最窄窗口（先收 Cue 再藏会话条，所以后一个总比前一个宽）。
    static func railThreshold(split: Bool) -> CGFloat { Chrome.rail + narrowestMain(split: split) }

    static func cueThreshold(split: Bool) -> CGFloat { railThreshold(split: split) + cue }
}

extension View {
    /// 宽屏窗口的根（Mac 的 `MainWindow`、iPad 的 `SplitRoot`）把这一刻放不放得下报给工作区：抽屉开没开只在 `Workspace.fit` 一处随它清。
    func reportsWideFits(_ sizes: WideMetrics, to workspace: Workspace) -> some View {
        onChange(of: sizes.fits, initial: true) { _, fits in workspace.fit(fits) }
    }
}

extension View {
    /// 宽屏的一块（主区、并排的右半、Cue）伸到窗口下缘：iPad 的横条那一截也是这一块的，对话滚到窗口下缘、在回复框四周与横条后面透出来，
    /// 不在横条上沿切齐（同手机）；块里的页照样让出它（托管视图按块在窗口里的位置算下安全区，`WideColumnController`）。只容器的那一份：键盘升起时块照样变矮。
    func reachesWindowBottom() -> some View { ignoresSafeArea(.container, edges: .bottom) }
}
