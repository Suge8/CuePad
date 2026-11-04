import SwiftUI

/// 宽屏三栏的尺寸：会话条（宽 256、收起 80，`SessionRail.Form`）、主区、右边的 Cue（400；收起成一颗钮时 0）。
/// 只由窗口宽、主区放着什么与两个用户选择推出（会话条开合 `railExpanded`、Cue 开合 `cueOpen`）；自动收起只改呈现，不改这两个选择。
/// 窗口变窄时只往收里走：先把会话条收成 80，再把 Cue 收成钮；收 Cue 时不把会话条放回宽版——拖窗口的人会看见左边忽然又宽了。
/// 主区最窄：看板 756（四列最窄，`BoardColumns`）、并排两个会话各 400、其余 400。Mac 窗口与 iPad 同一套；
/// 只有 iPad 主区放不下四列时换竖版看板（`boardFits`），所以 iPad 收 Cue 按会话的最窄算，会话条仍按四列。
/// 1470 宽（13 寸 MacBook Air）开两个会话 + Cue 时会话条仍是宽版（256 + 800 + 400 = 1456）。
struct WideMetrics {
    static let board: CGFloat = 756
    static let session: CGFloat = 400
    static let cue: CGFloat = 400
    #if os(macOS)
    /// 窗口最顶那一排的高（红绿灯居中在它里面）：三栏的栏头都排在这一排，栏里的页从它下面开始（看板的列头就是这一排）。
    static let band: CGFloat = 52
    #else
    /// iPad 会话条顶上那一排（侧栏钮、搜索）的高。
    static let band: CGFloat = 44
    #endif

    let rail: CGFloat
    /// 主区（并排两个会话时是两半合起来）。
    let main: CGFloat
    let cue: CGFloat
    /// 主区并排两个会话。
    let split: Bool
    /// Cue 放得下：没露出来是用户收起的；放不下时收起的 Cue 钮点了是浮出。
    let cueFits: Bool

    /// 并排时左半的宽（只开一个时是整个主区）。
    var leading: CGFloat { split ? (main / 2).rounded() : main }

    /// 会话条与 Cue 的宽：它们一变，主区几块滑到新位置（`WideColumnView.move`）；只是窗口改宽时不滑。
    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
    }

    var shape: Shape { Shape(rail: rail, cue: cue) }

    init(width: CGFloat, workspace: Workspace) {
        let need = Self.minimum(workspace)
        let open = workspace.services.settings.cueOpen
        split = need.split
        rail = workspace.sidebarOpen && width >= Self.railThreshold(need: need.rail, cueOpen: open) ? SessionRail.Form.wide.width : SessionRail.Form.narrow.width
        cueFits = width >= rail + need.cue + Self.cue
        cue = open && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
    }

    /// 会话条自动收起的临界窗口宽：宽版会话条 + 主区最窄 + 开着的 Cue。
    static func railThreshold(_ workspace: Workspace) -> CGFloat {
        railThreshold(need: minimum(workspace).rail, cueOpen: workspace.services.settings.cueOpen)
    }

    /// Cue 自动收成钮的临界窗口宽（会话条已收成 80）。
    static func cueThreshold(_ workspace: Workspace) -> CGFloat {
        SessionRail.Form.narrow.width + minimum(workspace).cue + cue
    }

    private static func railThreshold(need: CGFloat, cueOpen: Bool) -> CGFloat {
        SessionRail.Form.wide.width + need + (cueOpen ? cue : 0)
    }

    private static func minimum(_ workspace: Workspace) -> (rail: CGFloat, cue: CGFloat, split: Bool) {
        if workspace.besideSession != nil { return (2 * session, 2 * session, true) }
        guard workspace.mainRoute == .progress else { return (session, session, false) }
        #if os(macOS)
        return (board, board, false)
        #else
        return (board, session, false)
        #endif
    }
}

extension EnvironmentValues {
    /// 宽屏主区放得下看板四列的最窄宽（`WideMetrics.board`）：放不下时 iPad 的进展页换成竖版看板（`ProgressScreen`），不把四列压窄。
    @Entry var boardFits = true
}
