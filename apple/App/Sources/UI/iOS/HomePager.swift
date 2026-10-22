#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏根上的四页按底部那一排的顺序（`Dock.pages`）横着排成一条：左右滑跟手切页，松手按甩出的方向停到一页；点底部那一排换去处时整条滑过去。
/// 当前页只有 `Workspace.root` 一份：松手、点按都经 `select`，条停在哪页跟着它走。
/// Cue 在最右，它右边是刚返回离开的那一页（`Workspace.forward`）：手指左滑把它拉回来。跟手的是离开前拍的快照（`LeaveShot`，同 Safari 的前进），
/// 同系统推入一样盖着 Cue 页滑进来、Cue 页与底部那一排慢慢退；松手推入真的页（不带动画），它画上屏后才收起快照。
/// 跟手与弹簧都在 SwiftUI 之外（`PagerController`）：每页各有自己的托管控制器，拖动只改图层的平移，松手的弹簧交给 Core Animation，
/// 一帧不重算 SwiftUI。环境整份转给每一页（`environment(\.self)`），页里读到的与挂在导航栈根上时一样。
/// 底部那一排与前进页的快照留在这一层 SwiftUI 里（托管视图点在空处也不往下交，盖在页上就挡住了页）：这一层没有页，只有它们俩读 `PagerMotion`，
/// 前进时每帧也只重算这两小块。
struct HomePager<Chrome: View>: View {
    /// Cue 页的输入框有焦点：这时不接横拖（选字、挪光标都是横着拖）。
    let composing: Bool
    let shot: LeaveShot
    /// 盖在页上、不随页滑的一层（底部那一排）：只在前进时随 Cue 页一起退。
    @ViewBuilder let chrome: Chrome
    @Environment(Workspace.self) private var workspace
    @State private var motion = PagerMotion()

    var body: some View {
        let root = workspace.root
        let forward = root == Dock.pages.last && workspace.forward != nil && shot.route == workspace.forward ? shot.view : nil
        PagerHost(workspace: workspace, motion: motion, root: root, forward: forward, composing: composing)
            .ignoresSafeArea()
            .overlay { chrome.modifier(Retreat(motion: motion)) }
            .overlay { ForwardPage(motion: motion).allowsHitTesting(false).accessibilityHidden(true) }
            // 跟手与弹簧在图层上，SwiftUI 看不出在动：截图要等停稳再拍
            .debugSettling(motion.busy)
    }
}

/// 容器告诉 SwiftUI 这一层的：条在不在动（截图等它停）、前进页拉出来多少。
@Observable
final class PagerMotion {
    var busy = false
    /// 拉出前进页的进度，0…1。
    var pushed: CGFloat = 0
    var width: CGFloat = 0
    /// 拉出来的是哪张快照（推入真的页、它画上屏之前还留着）。
    var shot: UIView?
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
