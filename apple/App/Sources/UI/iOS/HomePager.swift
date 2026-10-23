#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏根上的三页按底部那一排的顺序（`Dock.pages`）横着排成一条：左右滑跟手切页，松手按甩出的方向停到一页；点底部那一排换去处时整条滑过去。
/// 当前页只有 `Workspace.root` 一份：松手、点按都经 `select`，条停在哪页跟着它走。条此刻在哪只有 `PagerMotion` 一份（容器写、SwiftUI 读），
/// 拖、松手的弹簧、点按的弹簧都是同一条路（`PagerController.animate`），底部那一排的滴与换形读它，所以跟手、同一条弹簧、一起到位。
/// Cue 在最右，它右边是刚返回离开的那一页（`Workspace.forward`）：手指左滑把它拉回来。跟手的是离开前拍的快照（`LeaveShot`，同 Safari 的前进），
/// 同系统推入一样盖着 Cue 页滑进来、Cue 页与底部那一排慢慢退；松手推入真的页（不带动画），它画上屏后才收起快照。
/// 跟手与弹簧都在 SwiftUI 之外（`PagerController`）：每页各有自己的托管控制器，拖动只改图层的平移，松手的弹簧交给 Core Animation，
/// 页里只有 Cue 页的输入框逐帧换浓淡（`DockHandoff`），其余一帧不重算 SwiftUI。环境整份转给每一页（`environment(\.self)`），页里读到的与挂在导航栈根上时一样，
/// 所以这一层的 body 每重算一次，三页的内容就整份重设一遍：这里不读 `PagerMotion` 里会变的东西，读的都放进自己的小块里（`PagerSettling`、`Retreat`、`ForwardPage`）。
/// 底部那一排与前进页的快照留在这一层 SwiftUI 里（托管视图点在空处也不往下交，盖在页上就挡住了页）：每帧只重算读 `PagerMotion` 的那几小块。
struct HomePager<Chrome: View>: View {
    let motion: PagerMotion
    /// Cue 页的输入框有焦点：这时不接横拖（选字、挪光标都是横着拖）。
    let composing: Bool
    let shot: LeaveShot
    /// 盖在页上、不随页滑的一层（底部那一排）：只在前进时随 Cue 页一起退。
    @ViewBuilder let chrome: Chrome
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let root = workspace.root
        let forward = root == Dock.pages.last && workspace.forward != nil && shot.route == workspace.forward ? shot.view : nil
        PagerHost(workspace: workspace, motion: motion, root: root, forward: forward, composing: composing)
            .ignoresSafeArea()
            .overlay { chrome.modifier(Retreat(motion: motion)) }
            .overlay { ForwardPage(motion: motion).allowsHitTesting(false).accessibilityHidden(true) }
            .background { PagerSettling(motion: motion) }
    }
}

/// 跟手与弹簧在图层上，SwiftUI 看不出在动：截图要等停稳再拍。
private struct PagerSettling: View {
    let motion: PagerMotion

    var body: some View { Color.clear.debugSettling(motion.busy) }
}

/// 条此刻的样子，容器（`PagerController.apply`）写、SwiftUI 读：在不在动（截图等它停）、停在哪、前进页拉出来多少。
/// 底部那一排的样子也只从这里推出来（`places`）：三格还是"⋯"加输入框、底边归 Cue 钮还是页里的输入框，没有另一份状态。
/// 读的只是几小块（滴读 `position`，换形与输入框读 `places`），各读各的：拖动时每帧只重算读到变了的那几块。
@Observable
final class PagerMotion {
    var busy = false
    /// 条在第几页，连续的：拖到一半是 1.5。
    private(set) var position: CGFloat = 0
    /// 条有多少在 Cue 页上（从它左边那页滑过来的进度，0…1）。
    private(set) var onCue: CGFloat = 0
    /// Cue 页底部的"⋯"展开成了三格（`DockRoot.openPlaces` 带着弹簧改）。条一离开 Cue 页就收起：那时三格本来就是展开的，收不收看不出来，
    /// 回到 Cue 页就是收起的样子；与条怎么离开（滑、点、减弱动态效果时直接到位）无关。
    var placesOpen = false
    /// 拉出前进页的进度，0…1。
    private(set) var pushed: CGFloat = 0
    var width: CGFloat = 0
    /// 拉出来的是哪张快照（推入真的页、它画上屏之前还留着）。
    var shot: UIView?

    /// 底部那一排是三格的样子占几成：1 是三格，0 是"⋯"加输入框（`DockHandoff`）。
    var places: CGFloat { placesOpen ? 1 : 1 - onCue }

    func move(to position: CGFloat, pushed: CGFloat) {
        if self.position != position { self.position = position }
        let onCue = Self.onCue(at: position)
        if self.onCue != onCue { self.onCue = onCue }
        if onCue < 1, placesOpen { placesOpen = false }
        if self.pushed != pushed { self.pushed = pushed }
    }

    private static func onCue(at position: CGFloat) -> CGFloat { min(max(position - CGFloat(Dock.pages.count - 2), 0), 1) }
}

/// 前进时底部那一排随 Cue 页退开。
private struct Retreat: ViewModifier {
    let motion: PagerMotion

    func body(content: Content) -> some View { content.offset(x: -motion.pushed * PagerController.parallax * motion.width) }
}

/// 拉出来的前进页：快照盖着 Cue 页与底部那一排从右边滑进来，边上一道阴影（同系统推入）；没拉出来时什么都不挂。
private struct ForwardPage: View {
    let motion: PagerMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let pushed = motion.pushed
        if pushed > 0, let shot = motion.shot {
            ShotView(shot: shot)
                .ignoresSafeArea()
                .shadow(color: pushed < 1 ? palette.panelShadow : .clear, radius: 12)
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
    let motion: PagerMotion
    let root: Route
    let forward: UIView?
    let composing: Bool

    func makeUIViewController(context: Context) -> PagerController { PagerController(workspace: workspace, motion: motion) }

    func updateUIViewController(_ controller: PagerController, context: Context) {
        controller.update(.init(
            environment: context.environment, root: root, forward: forward, composing: composing,
            reduceMotion: context.environment.accessibilityReduceMotion))
    }
}
#endif
