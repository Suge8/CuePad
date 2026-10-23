#if os(iOS) && DEBUG
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// `IOSInteractionBench` 里要真手指的项：进程内没有入口（系统长按菜单）或要量的就是手势本身（滑动切页、右滑返回、左滑前进）。
/// App 写 `AWAIT 名 x y`（按）或 `AWAIT 名 x y x2 y2 swipe|drag 秒`（从前一点快滑或慢拖到后一点），屏幕坐标、名字里不带空格；`perf-ios.sh` 用 axe 在模拟器上真按、真滑，
/// 量从手指按下（`TouchProbe`）起算。每行的 `landed` 是量完时停在哪（`landed(_:)`），核对手势做了该做的事、没误触。
extension IOSInteractionBench {
    enum Finger {
        case press(CGPoint)
        /// 快滑（axe swipe）：切页、返回、快甩。
        case swipe(from: CGPoint, to: CGPoint, seconds: Double = 0.25)
        /// 慢拖（axe drag，逐点移动）：行的轻扫只认开始那一刻横向慢于 600pt/s 的拖。
        case drag(from: CGPoint, to: CGPoint, seconds: Double)
    }

    typealias Step = (_ name: String, _ window: Duration, _ finger: Finger?, _ action: () -> Void) async -> Void

    /// 滑动的几项量 1 秒：滑 0.25 秒、松手后转场还要走半秒，800ms 时常停在半路上。
    static let swipeWindow = Duration.milliseconds(1000)

    /// 手势切页、返回与前进（每项两遍），再在会话行与任务看板上横滑核对没被切页抢走。改前（切页还是点底部那一排）1、2、4 什么都不发生，3 是系统的返回。
    /// `press`：请脚本按或滑一下、不量（收起滑出的行动作）。
    static func gestures(
        _ workspace: Workspace, session: UUID, wants: (String) -> Bool, fail: (String) -> Never, press: (String, Finger) async -> Void, step: Step
    ) async {
        guard let bounds = window?.bounds else { return }
        let left = bounds.width / 4, right = bounds.width * 3 / 4, mid = bounds.midY
        func land(_ root: Route) async {
            workspace.select(root)
            try? await Task.sleep(for: .seconds(1))
        }
        for _ in 0..<2 {
            // Cue 在底部那一排最右：右滑去它左边的会话页，会话页左滑回 Cue
            if wants("滑动切页·Cue→会话") {
                await land(.cue)
                await step("滑动切页·Cue→会话", swipeWindow, .swipe(from: CGPoint(x: left, y: mid), to: CGPoint(x: right, y: mid))) {}
            }
            // 会话页的中部满是会话行（行上左滑露出行的动作），切页滑在第一行上面的分组标题那一条
            if wants("滑动切页·会话→Cue") {
                await land(.agent)
                let row = sessionRow(in: window, fail: fail)
                let y = row.minY - 20
                await step("滑动切页·会话→Cue", swipeWindow, .swipe(from: CGPoint(x: right, y: y), to: CGPoint(x: left, y: y))) {}
            }
            // 右滑返回从内容区起（x=60），不贴边；左滑前进紧接着回到的 Cue 页
            guard wants("右滑返回") || wants("左滑前进") else { continue }
            await land(.cue)
            workspace.openSession(session)
            try? await Task.sleep(for: .seconds(1.5))
            await step("右滑返回", swipeWindow, .swipe(from: CGPoint(x: 60, y: mid), to: CGPoint(x: right, y: mid))) {}
            await step("左滑前进", swipeWindow, .swipe(from: CGPoint(x: right, y: mid), to: CGPoint(x: left, y: mid))) {}
        }
        // 会话行：慢慢左拖 150pt（约 0.9 秒）露出行的动作；同一行上快甩是切页（会话页左边是 Cue）
        for _ in 0..<2 where wants("误触·会话行左滑") {
            await land(.cue)
            await land(.agent)
            let row = sessionRow(in: window, fail: fail)
            rowBefore = pixels(row)
            await step("误触·会话行左滑", .milliseconds(1500), .drag(from: CGPoint(x: right, y: row.midY), to: CGPoint(x: right - 150, y: row.midY), seconds: 0.9)) {}
            // 页常驻、不重建：滑出的行动作点一下行收起，不留给下一遍（没滑出时这一下会打开会话，也算没收起）
            await press("收起行动作", .press(CGPoint(x: left, y: row.midY)))
            try? await Task.sleep(for: .seconds(1))
            if landed(workspace) != "agent" { fail("点一下没收起行动作：\(landed(workspace))") }
            rowBefore = nil
        }
        for _ in 0..<2 where wants("会话行快甩") {
            await land(.cue)
            await land(.agent)
            let row = sessionRow(in: window, fail: fail).midY
            await step("会话行快甩", swipeWindow, .swipe(from: CGPoint(x: right, y: row), to: CGPoint(x: left, y: row), seconds: 0.12)) {}
        }
        for _ in 0..<2 where wants("误触·看板左滑") || wants("误触·看板右滑") {
            await land(.tasks)
            guard let board = boardY(in: window) else { fail("任务页上找不到看板") }
            await step("误触·看板左滑", swipeWindow, .swipe(from: CGPoint(x: right, y: board), to: CGPoint(x: left, y: board))) {}
            await step("误触·看板右滑", swipeWindow, .swipe(from: CGPoint(x: left, y: board), to: CGPoint(x: right, y: board))) {}
        }
    }

    /// 量完时停在哪：根与推入的页（`cue`、`cue>session`），露出了行的轻扫按钮记"+行动作"，任务页记看板此刻那一列。
    static func landed(_ workspace: Workspace) -> String {
        func brief(_ route: Route) -> String {
            switch route {
            case .project: "project"
            case .card: "card"
            case .session: "session"
            default: "\(route)"
            }
        }
        var text = ([workspace.root] + workspace.path).map(brief).joined(separator: ">")
        if workspace.root == .agent, workspace.path.isEmpty, let before = rowBefore, moved(before) { text += "+行动作" }
        if workspace.root == .tasks, let column = boardColumn(in: window) { text += " 列=\(column)" }
        return text
    }

    /// 请测量脚本按或滑，等手指按下那一刻再返回：量从按下起算。
    static func touch(_ write: @escaping (String) -> Void, _ name: String, _ finger: Finger) async {
        func xy(_ point: CGPoint) -> String { "\(Int(point.x)) \(Int(point.y))" }
        let args = switch finger {
        case let .press(point): xy(point)
        case let .swipe(from, to, seconds): "\(xy(from)) \(xy(to)) swipe \(seconds)"
        case let .drag(from, to, seconds): "\(xy(from)) \(xy(to)) drag \(seconds)"
        }
        await withCheckedContinuation { continuation in
            TouchProbe.arm { continuation.resume() }
            write("AWAIT \(name) \(args)")
        }
    }

    /// 手指按得到的视图：整个在屏内，中心点的命中落在它里面。根上四页都建着，挪到屏外的页 UIKit 的 frame 可能还在屏内，只看 frame 会认错页。
    private static func onScreen(_ view: UIView, _ window: UIWindow) -> CGRect? {
        let frame = view.convert(view.bounds, to: window)
        guard !view.isHidden, view.alpha > 0, window.bounds.contains(frame),
              window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)?.isDescendant(of: view) == true else { return nil }
        return frame
    }

    private static func all(in view: UIView?) -> [UIView] {
        guard let view, !view.isHidden else { return [] }
        return [view] + view.subviews.flatMap { all(in: $0) }
    }

    /// 会话列表（SwiftUI 的 List）里屏上的第一行。
    private static func sessionRow(in window: UIWindow?, fail: (String) -> Never) -> CGRect {
        guard let window, let row = all(in: window).compactMap({ $0 as? UICollectionViewCell }).compactMap({ onScreen($0, window) })
            .filter({ $0.height >= 44 }).min(by: { $0.minY < $1.minY })
        else { fail("会话页上找不到会话行") }
        return row
    }

    /// 任务看板（四列横排成一条的滚动区）：屏上最里层那个，外面可能还套着翻页的容器。
    private static func board(in window: UIWindow?) -> UIScrollView? {
        guard let window else { return nil }
        return all(in: window).compactMap { $0 as? UIScrollView }
            .last { $0.contentSize.width > $0.bounds.width * 1.5 && $0.bounds.height > 300 && onScreen($0, window) != nil }
    }

    private static func boardY(in window: UIWindow?) -> CGFloat? {
        guard let window, let board = board(in: window) else { return nil }
        return board.convert(board.bounds, to: window).midY
    }

    private static func boardColumn(in window: UIWindow?) -> TaskBoard.Column? {
        // 列不一定一屏宽（原型的一列半、空列收窄）：按四列平分内容宽估
        guard let board = board(in: window), board.contentSize.width > 0 else { return nil }
        let index = Int((board.contentOffset.x / (board.contentSize.width / CGFloat(TaskBoard.Column.allCases.count))).rounded())
        return TaskBoard.Column.allCases.indices.contains(index) ? TaskBoard.Column.allCases[index] : nil
    }

    /// 慢拖之前那一行的样子（`pixels`）：自绘的轻扫按钮是 SwiftUI 画的、不是 UIKit 视图，也不进读屏，只能比画面认。
    nonisolated(unsafe) private static var rowBefore: (rect: CGRect, pixels: [UInt8])?

    /// 窗口里 `rect` 那一块的像素（1 倍，RGBA）。
    private static func pixels(_ rect: CGRect) -> (rect: CGRect, pixels: [UInt8]) {
        let width = Int(rect.width), height = Int(rect.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.translateBy(x: -rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            window?.drawHierarchy(in: window?.bounds ?? .zero, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
        return (rect, buffer)
    }

    /// 那一行露出了动作：行整体左移一个托盘宽，和慢拖之前比超过 8% 的像素明显变了（卡片底色大块是白的，露出动作时约 17%，收着时是 0）。
    private static func moved(_ before: (rect: CGRect, pixels: [UInt8])) -> Bool {
        let now = pixels(before.rect).pixels
        var changed = 0
        for i in stride(from: 0, to: now.count, by: 4) {
            let diff = (0..<3).reduce(0) { $0 + abs(Int(now[i + $1]) - Int(before.pixels[i + $1])) }
            if diff > 60 { changed += 1 }
        }
        return Double(changed) / Double(now.count / 4) > 0.08
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
