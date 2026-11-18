import SwiftUI

/// 只由窗口宽、用户的两个开合选择（会话条 `AppSettings.railExpanded`、Cue `cueOpen`）与主区开了几个会话推出，不看主区放着什么页：换页时栏不动。
/// Cue 铺满时（`home`）没有主区：会话条之外全是它。
/// 自动收起只改呈现、不改选择：选了开着、窗口放不下时照样藏起，放得下了回到所选（HIG「Sidebars」：窗口变小时自动藏起侧栏，同邮件）。
/// 窗口变窄时先把 Cue 收成钮，再藏起会话条：会话条是换去处的地方，点它的一行不该让它自己消失；Cue 收着时一下就回得去（它那一行、右上的钮）。
/// 主区最窄是一个会话的宽，并排开着时是两个：并排是用户自己开的，栏跟着让位读得出原因。
/// Mac 上右半开着（第二个会话或活预览）时 Cue 收成钮（`cueYields`；同样只改呈现，`cueOpen` 不动，收起右半就回到所选）：主区是正在干的活、先拿宽，
/// Cue 是总控、有余地才占一栏，在钮里一下就回得去；收起与右半滑出是同一次换形（`shape`），同一段滑动。
/// 两半的分界可拖（`BesideShare`），右半是会话、是预览各记一份比例；两边各不窄于自己的最窄（`trailingMin`）。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    /// Mac 的含浮板四周那一圈（`CueColumn.float`）：板本身 372，名牌（`CueTitle.width`）连收起钮放得下四项数字账。
    #if os(macOS)
    static let cue: CGFloat = 388
    #else
    static let cue: CGFloat = 400
    #endif

    let home: Bool
    let rail: CGFloat
    let railFits: Bool
    let main: CGFloat
    let cue: CGFloat
    let split: Bool
    let preview: Bool
    let cueFits: Bool
    private let share: CGFloat

    #if os(macOS)
    /// 活预览最窄：手机宽那一档连两侧留白放得下。
    static let previewWidth = LivePreview.phoneWidth + 2 * Spacing.page
    #else
    static let previewWidth: CGFloat = 0
    #endif

    /// 右半占主区的几成（每个窗口一份，`Workspace.besideShare`）：两个会话各半；看网页要比看对话宽，预览默认约六成。
    struct BesideShare: Equatable {
        var session: CGFloat = 0.5
        var preview: CGFloat = 0.6

        subscript(preview preview: Bool) -> CGFloat {
            get { preview ? self.preview : session }
            set { if preview { self.preview = newValue } else { session = newValue } }
        }
    }

    /// 右半开着时 Cue 收不收成钮：只有 Mac 收（iPad 的并排照旧按窗口宽）。
    static func cueYields(split: Bool) -> Bool {
        #if os(macOS)
        split
        #else
        false
        #endif
    }

    var leading: CGFloat {
        guard split else { return main }
        #if os(macOS)
        return Self.leading(main: main, share: share, preview: preview)
        #else
        return (main / 2).rounded()
        #endif
    }

    /// 并排时右半的宽；不并排时是此刻开出右半会有的宽（Mac 的右半一直挂着，`MainWindow.beside`）。
    var trailing: CGFloat { main - (split ? leading : (main / 2).rounded()) }

    static func trailingMin(preview: Bool) -> CGFloat { preview ? previewWidth : session }

    /// 右半占 `share` 时左边会话的宽：两边各不窄于自己的最窄（主区放不下两者时先保左边）。
    static func leading(main: CGFloat, share: CGFloat, preview: Bool) -> CGFloat {
        max(session, min(main - trailingMin(preview: preview), (main * (1 - share)).rounded()))
    }

    /// 宽屏看板"列头就是最顶那一排、范围钮在开头"：列让出栏头左边与那颗钮，卡片自带的那一圈不算。
    static func boardLead(_ inset: EdgeInsets) -> CGFloat { inset.leading + Spacing.item + Chrome.control - BoardCardMetrics.inset }

    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
        var split = false
    }

    /// 铺满的 Cue 随窗口变宽，不算换了形：拖窗口时不起滑动。
    /// Mac 上并排开合也算换形：右半那一块从主区右缘长出来、收回去（`MainWindow` 一直挂着它）；iPad 的右半只在并排时挂，开合照旧直接到位。
    #if os(macOS)
    var shape: Shape { Shape(rail: rail, cue: home ? -1 : cue, split: split) }
    #else
    var shape: Shape { Shape(rail: rail, cue: home ? -1 : cue) }
    #endif

    struct Fits: Equatable {
        let rail: Bool
        let cue: Bool
    }

    var fits: Fits { Fits(rail: railFits, cue: cueFits) }

    init(width: CGFloat, workspace: Workspace) {
        home = workspace.cueHome
        split = workspace.beside != nil
        preview = workspace.beside == .preview
        let narrowest = split ? Self.session + Self.trailingMin(preview: preview) : Self.session
        railFits = width >= Chrome.rail + narrowest
        rail = workspace.sidebarOpen && railFits ? Chrome.rail : 0
        cueFits = home || !Self.cueYields(split: split) && width >= rail + narrowest + Self.cue
        cue = home ? width - rail : workspace.services.settings.cueOpen && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
        #if os(macOS)
        share = workspace.besideShare[preview: preview]
        #else
        share = BesideShare()[preview: preview]
        #endif
    }

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
