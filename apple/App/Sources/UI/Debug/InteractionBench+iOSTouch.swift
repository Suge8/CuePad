#if os(iOS) && DEBUG
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// `IOSInteractionBench` 里要真手指的项：进程内没有入口（系统长按菜单）或要量的就是手势本身（右滑返回）。
/// App 写 `AWAIT 名 x y`（按）或 `AWAIT 名 x y x2 y2 swipe 秒`（从前一点快滑到后一点），屏幕坐标、名字里不带空格；`perf-ios.sh` 用 axe 在模拟器上真按、真滑，
/// 量从手指按下（`TouchProbe`）起算。每行的 `landed` 是量完时停在哪（`landed(_:)`），核对手势做了该做的事。
extension IOSInteractionBench {
    enum Finger {
        case press(CGPoint)
        /// 快滑（axe swipe）：返回。
        case swipe(from: CGPoint, to: CGPoint, seconds: Double = 0.25)
    }

    typealias Step = (_ name: String, _ window: Duration, _ finger: Finger?, _ action: () -> Void) async -> Void

    /// 滑动的几项量 1 秒：滑 0.25 秒、松手后转场还要走半秒，800ms 时常停在半路上。
    static let swipeWindow = Duration.milliseconds(1000)

    /// 右滑返回（两遍）：Cue 页推入一个会话，从内容区起（x=60，不贴边）右滑回到 Cue 页。
    static func gestures(_ workspace: Workspace, session: UUID, wants: (String) -> Bool, step: Step) async {
        guard wants("右滑返回"), let bounds = window?.bounds else { return }
        let right = bounds.width * 3 / 4, mid = bounds.midY
        for _ in 0..<2 {
            workspace.select(.cue)
            await Task.wait(for: .seconds(1))
            workspace.openSession(session)
            await Task.wait(for: .seconds(1.5))
            await step("右滑返回", swipeWindow, .swipe(from: CGPoint(x: 60, y: mid), to: CGPoint(x: right, y: mid))) {}
        }
    }

    /// 量完时停在哪：选中的 tab 与它推入的页（`cue`、`cue>session`）。
    static func landed(_ workspace: Workspace) -> String {
        func brief(_ route: Route) -> String {
            switch route {
            case .project: "project"
            case .card: "card"
            case .session: "session"
            default: "\(route)"
            }
        }
        return ([workspace.root] + workspace.path).map(brief).joined(separator: ">")
    }

    /// 请测量脚本按或滑，等手指按下那一刻再返回：量从按下起算。
    static func touch(_ write: @escaping (String) -> Void, _ name: String, _ finger: Finger) async {
        func xy(_ point: CGPoint) -> String { "\(Int(point.x)) \(Int(point.y))" }
        let args = switch finger {
        case let .press(point): xy(point)
        case let .swipe(from, to, seconds): "\(xy(from)) \(xy(to)) swipe \(seconds)"
        }
        await withCheckedContinuation { continuation in
            TouchProbe.arm { continuation.resume() }
            write("AWAIT \(name) \(args)")
        }
    }

    private static func menuInteractions(in view: UIView?) -> [UIInteraction] {
        guard let view else { return [] }
        let here = view.interactions.filter { $0 is UIContextMenuInteraction || String(describing: type(of: $0)).contains("ClickPresentation") }
        return here + view.subviews.flatMap { menuInteractions(in: $0) }
    }

    /// 收起开着的长按菜单：系统的菜单交互收起，SwiftUI 的点按呈现交互取消。
    static func dismissMenus() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for interaction in windows.flatMap({ menuInteractions(in: $0) }) {
            if let menu = interaction as? UIContextMenuInteraction { menu.dismissMenu() } else {
                let cancel = NSSelectorFromString("cancelInteraction")
                if interaction.responds(to: cancel) { interaction.perform(cancel) }
            }
        }
    }

    /// 书架上带长按菜单的项目卡（SwiftUI 的长按菜单在视图上挂着点按呈现交互）的中心点，屏幕坐标。
    static func longPressTarget(in view: UIView?) -> CGPoint? {
        guard let view, !view.isHidden, view.alpha > 0, let window = view.window ?? (view as? UIWindow) else { return nil }
        let menu = view.interactions.contains { String(describing: type(of: $0)).contains("ClickPresentation") }
        let frame = view.convert(view.bounds, to: window)
        if menu, frame.width > 100, frame.height > 40, window.bounds.contains(frame) { return CGPoint(x: frame.midX, y: frame.midY) }
        for sub in view.subviews { if let found = longPressTarget(in: sub) { return found } }
        return nil
    }
}

/// 窗口里手指按下的那一刻（测量脚本在模拟器上真按、真滑）：每个窗口挂一个（长按菜单弹在自己的窗口里），只看不拦，按下就报给等着的一方。
private final class TouchProbe: UIGestureRecognizer {
    private static var waiting: (() -> Void)?

    static func arm(_ pressed: @escaping () -> Void) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchProbe }) {
            let probe = TouchProbe(target: nil, action: nil)
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false
            probe.delaysTouchesEnded = false
            window.addGestureRecognizer(probe)
        }
        waiting = pressed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.waiting?()
        Self.waiting = nil
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
