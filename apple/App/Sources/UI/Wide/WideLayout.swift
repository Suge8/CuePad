import SwiftUI

/// 宽屏三栏的尺寸：会话条（宽 `Chrome.rail`、收起是图标条 `Chrome.strip`）、主区、右边的 Cue（400；收起成一颗钮时 0）。
/// 只由窗口宽与用户的两个开合选择推出（会话条 `AppSettings.railExpanded`、Cue `cueOpen`），不看主区放着什么页：换页时栏不动。
/// 自动收起只改呈现、不改选择：选了宽版、窗口放不下时照样收成图标条，放得下了回到所选。
/// 窗口变窄时只往收里走：先把会话条收成图标条，再把 Cue 收成钮；收 Cue 时不把会话条放回宽版——拖窗口的人会看见左边忽然又宽了。
/// Cue 收成钮后点它从窗口右缘拉出抽屉（`Workspace.cueDrawer`），不占主区的宽。
/// 主区最窄只有一个数（`narrowestMain`）：并排两个会话各 390。看板在里面四列等分，放不下就整排横滑（`BoardColumns`）。
/// Mac：会话条宽版要 256 + 780 + 400 = 1436，图标条 + Cue 要 98 + 780 + 400 = 1278（1280 宽的小窗正好放得下）；iPad 图标条 80，要 1260。
/// 否决过：按主区放的页各算一份最窄（看板 776、会话 390），再给看板另记一份会话条开合——同一个窗口宽在不同页上栏宽不同，换页时会话条自己开合、读不出规律。
struct WideMetrics {
    static let session: CGFloat = 390
    static let cue: CGFloat = 400
    /// 主区最窄：并排两个会话。
    static let narrowestMain: CGFloat = 2 * session

    let rail: CGFloat
    /// 主区（并排两个会话时是两半合起来）。
    let main: CGFloat
    let cue: CGFloat
    /// 主区并排两个会话。
    let split: Bool
    /// Cue 放得下：没露出来是用户收起的；放不下时 Cue 钮拉出抽屉。
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
        let open = workspace.services.settings.cueOpen
        split = workspace.besideSession != nil
        rail = workspace.sidebarOpen && width >= Self.railThreshold(cueOpen: open) ? Chrome.rail : Chrome.strip
        cueFits = width >= rail + Self.narrowestMain + Self.cue
        cue = open && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
    }

    /// 会话条自动收起的临界窗口宽：宽版会话条 + 主区最窄 + 开着的 Cue。
    static func railThreshold(cueOpen: Bool) -> CGFloat {
        Chrome.rail + narrowestMain + (cueOpen ? cue : 0)
    }

    /// Cue 自动收成钮的临界窗口宽（会话条已收成图标条）。
    static var cueThreshold: CGFloat { Chrome.strip + narrowestMain + cue }
}
