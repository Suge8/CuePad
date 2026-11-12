import SwiftUI

/// 只由窗口宽、用户的两个开合选择（会话条 `AppSettings.railExpanded`、Cue `cueOpen`）与主区开了几个会话推出，不看主区放着什么页：换页时栏不动。
/// Cue 铺满时（`home`）没有主区：会话条之外全是它。
/// 自动收起只改呈现、不改选择：选了开着、窗口放不下时照样藏起，放得下了回到所选（HIG「Sidebars」：窗口变小时自动藏起侧栏，同邮件）。
/// 窗口变窄时先把 Cue 收成钮，再藏起会话条：会话条是换去处的地方，点它的一行不该让它自己消失；Cue 收着时一下就回得去（它那一行、右上的钮）。
/// 主区最窄是一个会话的宽，并排开着时是两个：并排是用户自己开的，栏跟着让位读得出原因。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    static let cue: CGFloat = 400

    let home: Bool
    let rail: CGFloat
    let railFits: Bool
    let main: CGFloat
    let cue: CGFloat
    let split: Bool
    let cueFits: Bool

    var leading: CGFloat { split ? (main / 2).rounded() : main }

    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
    }

    /// 铺满的 Cue 随窗口变宽，不算换了形：拖窗口时不起滑动。
    var shape: Shape { Shape(rail: rail, cue: home ? -1 : cue) }

    struct Fits: Equatable {
        let rail: Bool
        let cue: Bool
    }

    var fits: Fits { Fits(rail: railFits, cue: cueFits) }

    init(width: CGFloat, workspace: Workspace) {
        home = workspace.cueHome
        split = !home && workspace.besideSession != nil
        let narrowest = Self.narrowestMain(split: split)
        railFits = width >= Chrome.rail + narrowest
        rail = workspace.sidebarOpen && railFits ? Chrome.rail : 0
        cueFits = home || width >= rail + narrowest + Self.cue
        cue = home ? width - rail : workspace.services.settings.cueOpen && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
    }

    static func narrowestMain(split: Bool) -> CGFloat { split ? 2 * session : session }

    static var railThreshold: CGFloat { Chrome.rail + narrowestMain(split: false) }

    static func cueThreshold(rail: Bool) -> CGFloat { (rail ? Chrome.rail : 0) + narrowestMain(split: false) + cue }
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
