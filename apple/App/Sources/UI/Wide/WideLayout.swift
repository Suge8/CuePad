import SwiftUI

/// 宽屏三栏的尺寸：会话条（宽 `Chrome.rail`，藏起时 0）、主区、右边的 Cue（400；收起成一颗钮时 0）。
/// 只由窗口宽与用户的两个开合选择推出（会话条 `AppSettings.railExpanded`、Cue `cueOpen`），不看主区放着什么页：换页时栏不动。
/// 自动收起只改呈现、不改选择：选了开着、窗口放不下时照样藏起，放得下了回到所选（HIG「Sidebars」：窗口变小时自动藏起侧栏，同邮件）。
/// 窗口变窄时只往收里走：先藏起会话条，再把 Cue 收成钮；收 Cue 时不把会话条放回来——拖窗口的人会看见左边忽然又多出一栏。
/// Cue 收成钮后点它从窗口右缘拉出抽屉（`Workspace.cueDrawer`），会话条藏起后放不下时开合钮从左缘拉出抽屉（`Workspace.railDrawer`）：都不占主区的宽，
/// 再窄的窗口（竖着的 iPad）也够得着导航。
/// 主区最窄只有一个数（`narrowestMain`）：并排两个会话各 390。看板在里面四列等分，放不下就整排横滑（`BoardColumns`）。
/// 会话条 + Cue 要 256 + 780 + 400 = 1436；会话条藏起、Cue 露着要 780 + 400 = 1180；再窄 Cue 收成钮（Mac、iPad 同一组数）。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    static let cue: CGFloat = 400
    /// 主区最窄：并排两个会话。
    static let narrowestMain: CGFloat = 2 * session

    let rail: CGFloat
    /// 会话条放得下：没露出来是用户藏起的；放不下时开合钮拉出左缘的抽屉（`Workspace.railDrawer`）。
    let railFits: Bool
    /// 主区（并排两个会话时是两半合起来）。
    let main: CGFloat
    let cue: CGFloat
    /// 主区并排两个会话。
    let split: Bool
    /// Cue 放得下：没露出来是用户收起的；放不下时 Cue 钮拉出抽屉。
    let cueFits: Bool

    /// 并排时左半的宽（只开一个时是整个主区）。
    var leading: CGFloat { split ? (main / 2).rounded() : main }

    /// 会话条与 Cue 的宽：它们一变，主区几块滑到新位置（`WideColumnSlide`）；只是窗口改宽时不滑。
    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
    }

    var shape: Shape { Shape(rail: rail, cue: cue) }

    /// 会话条、Cue 各自放不放得下：跨过临界宽（放得下↔放不下）的那一刻对应的抽屉关掉（`Workspace.fit`）。
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

    /// 会话条自动藏起的临界窗口宽：会话条 + 主区最窄 + 开着的 Cue。
    static func railThreshold(cueOpen: Bool) -> CGFloat {
        Chrome.rail + narrowestMain + (cueOpen ? cue : 0)
    }

    /// Cue 自动收成钮的临界窗口宽（会话条已藏起）。
    static var cueThreshold: CGFloat { narrowestMain + cue }
}

extension View {
    /// 宽屏窗口的根（Mac 的 `MainWindow`、iPad 的 `SplitRoot`）把这一刻放不放得下报给工作区：抽屉开没开只在 `Workspace.fit` 一处随它清。
    func reportsWideFits(_ sizes: WideMetrics, to workspace: Workspace) -> some View {
        onChange(of: sizes.fits, initial: true) { _, fits in workspace.fit(fits) }
    }
}
