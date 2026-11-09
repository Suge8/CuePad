import SwiftUI

/// 只由窗口宽与用户的两个开合选择推出（会话条 `AppSettings.railExpanded`、Cue `cueOpen`），不看主区放着什么页：换页时栏不动。
/// 自动收起只改呈现、不改选择：选了开着、窗口放不下时照样藏起，放得下了回到所选（HIG「Sidebars」：窗口变小时自动藏起侧栏，同邮件）。
/// 窗口变窄时只往收里走：先藏起会话条，再把 Cue 收成钮；收 Cue 时不把会话条放回来——拖窗口的人会看见左边忽然又多出一栏。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    static let cue: CGFloat = 400
    static let narrowestMain: CGFloat = 2 * session

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

    var shape: Shape { Shape(rail: rail, cue: cue) }

    struct Fits: Equatable {
        let rail: Bool
        let cue: Bool
    }

    var fits: Fits { Fits(rail: railFits, cue: cueFits) }

    init(width: CGFloat, workspace: Workspace) {
        let open = workspace.services.settings.cueOpen
        split = workspace.besideSession != nil
        railFits = width >= Self.railThreshold(cueOpen: open)
        rail = workspace.sidebarOpen && railFits ? Chrome.rail : 0
        cueFits = width >= rail + Self.narrowestMain + Self.cue
        cue = open && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
    }

    static func railThreshold(cueOpen: Bool) -> CGFloat {
        Chrome.rail + narrowestMain + (cueOpen ? cue : 0)
    }

    static var cueThreshold: CGFloat { narrowestMain + cue }
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
