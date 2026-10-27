#if os(iOS)
import SwiftUI
import UIKit

/// Cue 页上能前进回去的那一页：推在 Cue 页上的页返回离开前拍下的整栈快照（连同顶栏）与它是哪一页，只留最近一张；左滑前进时先拿快照跟手（`DockPager`）。
/// 拍一张要等渲染服务交出那一份（几毫秒，压在返回转场的头一帧上），所以只拍用得上的：只有 Cue 的栈推入的页挂它（别的 tab 没有前进），
/// 被别的页盖住时不拍；换 tab、前进回去了就忘（`forget`）。
@Observable
final class LeaveShot {
    private(set) var route: Route?
    private(set) var view: UIView?

    func forget() {
        route = nil
        view = nil
    }

    fileprivate func take(_ route: Route, from controller: UIViewController) {
        guard let stack = controller.navigationController else { return }
        // 还在栈里是被盖住，不在了才是返回（导航栈在 viewWillDisappear 之前就换好了栈）
        let covered = sequence(first: controller, next: \.parent).contains { page in stack.viewControllers.contains { $0 === page } }
        guard !covered, let view = stack.view.snapshotView(afterScreenUpdates: false) else { return }
        self.route = route
        self.view = view
    }
}

extension View {
    /// 推入的页挂上它：返回离开前把整栈拍进 `shot`。
    func leaveShot(_ route: Route, into shot: LeaveShot) -> some View {
        background { LeaveProbe { shot.take(route, from: $0) } }
    }
}

/// 推入页里一个不占地方的子控制器：页要离开时（`viewWillDisappear`，转场开始之前、页还原样在屏上）报一声，返回还是被盖住由收的那边判。
private struct LeaveProbe: UIViewControllerRepresentable {
    let leaving: (UIViewController) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) { probe.leaving = leaving }

    final class Probe: UIViewController {
        var leaving: (UIViewController) -> Void = { _ in }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            leaving(self)
        }
    }
}
#endif
