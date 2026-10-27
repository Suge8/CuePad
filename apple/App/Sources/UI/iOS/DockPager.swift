#if os(iOS)
import SwiftUI
import UIKit

/// 三个 tab 按底部那一排的顺序（`Dock.tabs`）横着排成一条：左右滑跟手切 tab，松手按甩出的方向停到一页；点底部那一排换 tab 时整条滑过去。
/// 选中哪个 tab 只有 `Workspace.root` 一份：松手、点按都请它换（`Workspace.tap`），条跟着它走。条此刻在哪只有 `DockMotion` 一份（容器写、SwiftUI 读），
/// 拖、松手的弹簧、点按的弹簧都是同一条路（`PagerController.animate`），底部那一排的选中与换形读它，所以跟手、同一条弹簧、一起到位。
/// Cue 在最右，它右边是刚返回离开的那一页（`LeaveShot`）：手指左滑把它拉回来。跟手的是离开前拍的快照（`LeaveShot`，同 Safari 的前进），
/// 同系统推入一样盖着 Cue 页滑进来、Cue 页慢慢退（底部那一排在条之上，留在原处，前进的页让开它时随拉出淡去，`DockBar`）；松手推入真的页（不带动画），它画上屏后才收起快照。
/// 跟手与弹簧都在 SwiftUI 之外（`PagerController`）：每页各有自己的托管控制器，拖动只改图层的平移，松手的弹簧交给 Core Animation，
/// 页里只有 Cue 页的输入框逐帧换浓淡（`DockHandoff`），其余一帧不重算 SwiftUI。环境整份转给每一页（`environment(\.self)`），
/// 所以这一层的 body 每重算一次，三页的内容就整份重设一遍：这里不读 `DockMotion` 里会变的东西，读的都放进自己的小块里（`PagerSettling`、`ForwardPage`）。
struct DockPager: View {
    let motion: DockMotion
    let shot: LeaveShot
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let root = workspace.root
        let forward = root == .cue ? shot.view : nil
        PagerHost(workspace: workspace, motion: motion, shot: shot, root: root, forward: forward)
            .ignoresSafeArea()
            .overlay { ForwardPage(motion: motion).allowsHitTesting(false).accessibilityHidden(true) }
            .background { PagerSettling(motion: motion) }
    }
}

/// 跟手与弹簧在图层上，SwiftUI 看不出在动：截图要等停稳再拍。
private struct PagerSettling: View {
    let motion: DockMotion

    var body: some View { Color.clear.debugSettling(motion.busy) }
}

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
    var covered: Bool { !workspace[stack: .cue].isEmpty }

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

/// 拉出来的前进页：快照盖着 Cue 页从右边滑进来，边上一道阴影（同系统推入）；没拉出来时什么都不挂。
private struct ForwardPage: View {
    let motion: DockMotion

    var body: some View {
        let pushed = motion.pushed
        if pushed > 0, let shot = motion.shot {
            ShotView(shot: shot)
                .ignoresSafeArea()
                .elevation(pushed < 1 ? .lifted : nil)
                .offset(x: (1 - pushed) * motion.width)
        }
    }
}

/// 把快照挂进页里（左上对齐，原尺寸）。
private struct ShotView: UIViewRepresentable {
    let shot: UIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard shot.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        shot.frame.origin = .zero
        host.addSubview(shot)
    }
}

private struct PagerHost: UIViewControllerRepresentable {
    let workspace: Workspace
    let motion: DockMotion
    let shot: LeaveShot
    let root: Route
    let forward: UIView?

    func makeUIViewController(context: Context) -> PagerController { PagerController(workspace: workspace, motion: motion, shot: shot) }

    func updateUIViewController(_ controller: PagerController, context: Context) {
        controller.update(.init(
            environment: context.environment, root: root, forward: forward,
            reduceMotion: context.environment.accessibilityReduceMotion))
    }
}
#endif
