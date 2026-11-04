import SwiftUI

/// 宽屏三栏的尺寸：会话条（宽 `Chrome.rail`、收起是图标条 `Chrome.strip`）、主区、右边的 Cue（400；收起成一颗钮时 0）。
/// 只由窗口宽、主区放着什么与两个用户选择推出（会话条开合 `railExpanded`、Cue 开合 `cueOpen`）；自动收起只改呈现，不改这两个选择。
/// 窗口变窄时只往收里走：先把会话条收成图标条，再把 Cue 收成钮；收 Cue 时不把会话条放回宽版——拖窗口的人会看见左边忽然又宽了。
/// 主区最窄：Mac 看板 776（四列最窄 732，`BoardColumns.narrowest`，加列头那一排末尾"⋯"的一截 `boardMenu`）、并排两个会话各 390、其余 390。Mac 窗口与 iPad 同一套；
/// 只有 iPad 主区放不下四列时换竖版看板（`boardFits`），所以 iPad 收 Cue 按会话的最窄算，会话条仍按四列。
/// 1470 宽（13 寸 MacBook Air）看板 + Cue、两个会话 + Cue 时会话条都是宽版（256 + 776 + 400 = 1432、256 + 780 + 400 = 1436）；
/// 1280 宽（常见的小窗）看板 + Cue、两个会话 + Cue 都放得下（98 + 776 + 400 = 1274、98 + 780 + 400 = 1278）：页边收到 24、会话最窄收到 390，正为这两条。
struct WideMetrics {
    #if os(macOS)
    static var board: CGFloat { BoardColumns.narrowest(margin: TaskBoardPage.margin) }
    /// Mac 看板右边让给最顶那一排末尾的"⋯"（列头与它同一排，`TaskBoardPage`）：钮前那道缝与圆钮——栏头右边距与看板的页边、卡离列边加起来一样多，抵掉了。
    /// 算进主区放看板的最窄宽：少了它，正好在临界宽时最后一列钻到"⋯"底下、要横滑才看得全。
    static var boardMenu: CGFloat { Spacing.toolbarGap + ControlMetrics.height }
    #else
    static let board: CGFloat = 756
    #endif
    static let session: CGFloat = 390
    static let cue: CGFloat = 400

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
        rail = workspace.sidebarOpen && width >= Self.railThreshold(need: need.rail, cueOpen: open) ? Chrome.rail : Chrome.strip
        cueFits = width >= rail + need.cue + Self.cue
        cue = open && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
    }

    /// 会话条自动收起的临界窗口宽：宽版会话条 + 主区最窄 + 开着的 Cue。
    static func railThreshold(_ workspace: Workspace) -> CGFloat {
        railThreshold(need: minimum(workspace).rail, cueOpen: workspace.services.settings.cueOpen)
    }

    /// Cue 自动收成钮的临界窗口宽（会话条已收成图标条）。
    static func cueThreshold(_ workspace: Workspace) -> CGFloat {
        Chrome.strip + minimum(workspace).cue + cue
    }

    private static func railThreshold(need: CGFloat, cueOpen: Bool) -> CGFloat {
        Chrome.rail + need + (cueOpen ? cue : 0)
    }

    private static func minimum(_ workspace: Workspace) -> (rail: CGFloat, cue: CGFloat, split: Bool) {
        if workspace.besideSession != nil { return (2 * session, 2 * session, true) }
        guard workspace.mainRoute == .progress else { return (session, session, false) }
        #if os(macOS)
        return (board + boardMenu, board + boardMenu, false)
        #else
        return (board, session, false)
        #endif
    }
}

extension EnvironmentValues {
    /// 宽屏主区放得下看板四列的最窄宽（`WideMetrics.board`）：放不下时 iPad 的进展页换成竖版看板（`ProgressScreen`），不把四列压窄。
    @Entry var boardFits = true
}
