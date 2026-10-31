#if os(iOS)
import SwiftUI

/// 底部那一排与条此刻的样子，容器（`PagerController.apply`）写、SwiftUI 读：在不在动（截图等它停）、停在哪、前进页拉出来多少。
/// 底部那一排的样子也只从这里推出来（`places`）：两格还是"⋯"加输入框、底边归 Cue 钮还是页里的输入框，没有另一份状态。
/// 读的只是几小块（标签栏读 `tab`，换形与输入框读 `places`），各读各的：拖动时每帧只重算读到变了的那几块，标签栏只在过半换格时重算。
@Observable
final class DockMotion {
    @ObservationIgnored private let workspace: Workspace
    var busy = false
    /// 选中哪一格（`Dock.places` 的序号；在 Cue 上时为 nil）：拖动时是条离哪一格最近（过半才换），松手、点按时是要去的那一格。
    private(set) var tab: Int?
    /// 条有多少在 Cue 页上（从它左边那页滑过来的进度，0…1）。
    private var onCue: CGFloat = 0
    /// Cue 页底部的"⋯"展开成了两格（`DockRoot.openPlaces` 带着弹簧改）。条一离开 Cue 页就收起：那时两格本来就是展开的，收不收看不出来，
    /// 回到 Cue 页就是收起的样子；与条怎么离开（滑、点、减弱动态效果时直接到位）无关。
    var placesOpen = false
    /// Cue 页的输入框有焦点：底部那一排让开、输入框占满整排，条不接横拖。Cue 页在焦点进出时带着弹簧改（`CuePage`），
    /// 它与底部那一排各在一棵 SwiftUI 树里，读的是这同一份，所以输入框长宽与"⋯"淡出在同一次动画里。
    var composing = false
    /// 拉出前进页的进度，0…1。
    private(set) var pushed: CGFloat = 0
    var width: CGFloat = 0
    /// 拉出来的是哪张快照（推入真的页、它画上屏之前还留着）。
    var shot: UIView?

    init(workspace: Workspace) { self.workspace = workspace }

    /// Cue 的栈上推入了页、盖着 Cue 页：输入框在 Cue 页里，底部那一排总是两格。
    var covered: Bool { !workspace.path.isEmpty }

    /// 底部那一排是两格的样子占几成：1 是两格，0 是"⋯"加输入框（`DockHandoff`）。
    var places: CGFloat { placesOpen || covered ? 1 : 1 - onCue }

    /// `position`：条在第几页，连续的，拖到一半是 1.5；`tab`：选中的是第几个 tab。
    func move(to position: CGFloat, tab: Int, pushed: CGFloat) {
        let tab = Dock.places.indices.contains(tab) ? tab : nil
        if self.tab != tab { self.tab = tab }
        let onCue = min(max(position - CGFloat(Dock.tabs.count - 2), 0), 1)
        if self.onCue != onCue { self.onCue = onCue }
        if onCue < 1, placesOpen { placesOpen = false }
        if self.pushed != pushed { self.pushed = pushed }
    }
}

#endif
