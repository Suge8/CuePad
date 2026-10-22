#if os(iOS)
import SwiftUI
import UIKit

/// 推入的页离开前（返回、被别的页盖住）拍下的整栈快照（连同顶栏），只留最近一张：Cue 页上左滑前进时先拿它跟手（`HomePager`）。
/// 只有推在 Cue 页上的页挂它（别的根上没有前进）：拍一张要等渲染服务交出那一份，约几毫秒。
@Observable
final class LeaveShot {
    private(set) var route: Route?
    private(set) var view: UIView?

    fileprivate func take(_ route: Route, from controller: UIViewController) {
        guard let stack = controller.navigationController?.view, let view = stack.snapshotView(afterScreenUpdates: false) else { return }
        self.route = route
        self.view = view
    }
}

extension View {
    /// 推入的页挂上它：离开前把整栈拍进 `shot`。
    func leaveShot(_ route: Route, into shot: LeaveShot) -> some View {
        background { LeaveProbe { shot.take(route, from: $0) } }
    }
}

/// 推入页里一个不占地方的子控制器：页要离开时（`viewWillDisappear`，转场开始之前、页还原样在屏上）报一声。
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
