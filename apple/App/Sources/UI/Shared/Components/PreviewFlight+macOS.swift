#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// Mac 全屏预览的飞出、飞回（iOS 是系统的 zoom 转场）：打开时点的那张缩略图从原处长到内容落下的地方，关上时翻到的那一份缩回它自己的缩略图
/// （那张不在屏上时只随浮层淡出）。飞的是缩略图的那张画面，一层 Core Animation 图层浮在整窗最上面，位置、尺寸与圆角都在渲染端走 `Motion.move`
/// 的曲线（定长 0.24 秒、不回弹），主线程不逐帧重排（docs/ui.md「Mac 上开合不逐帧挪位置」）；飞完那张画面淡掉（`Motion.crossfade`）。
/// 关上时从屏上此刻的样子飞回（`PreviewShown`）：放大、拖过的图从露出的那一截连着缩回去。
/// 飞的这段内容藏着（`landed`），同一张图不会在两处同时出现：不用盖一层幕布——浮层淡入淡出时 SwiftUI 按层各自改透明度，半透明的幕布盖不住半透明的内容。
/// 内容区上不占地方的 `Stage` 是飞的终点与起点：它知道翻到了哪一份、内容落在哪。浮层本身的淡入淡出在 `PanelLayer`。减弱动态效果时不飞，只淡。
/// 缩略图（`previewSource`）在这里登记：画面在它的图层里、几十上百张一屏，只登记一个不占地方的平台视图，飞的那一下才取框，不给每张挂几何读数。
@MainActor final class PreviewFlight {
    fileprivate struct Source {
        weak var view: NSView?
        let image: () async -> CGImage?
        let aspect: CGFloat?
        let radius: CGFloat
    }

    private var sources: [PreviewZoomKey: Source] = [:]
    private var shows: [UUID: WeakShowing] = [:]
    fileprivate weak var stage: Stage.Mark?

    fileprivate func register(_ key: PreviewZoomKey, _ source: Source) { sources[key] = source }

    fileprivate func unregister(_ key: PreviewZoomKey, view: NSView) {
        if sources[key]?.view === view { sources[key] = nil }
    }

    /// 屏上看得见的那张（被滚出去的、懒加载撤掉的不算）。
    private func source(_ key: PreviewZoomKey, in window: NSWindow) -> (Source, CGRect)? {
        guard let source = sources[key], let view = source.view, view.window === window, !view.visibleRect.isEmpty else { return nil }
        return (source, view.convert(view.bounds, to: nil))
    }

    /// 全屏页的内容区第一次排好：从点的那张飞过去，落地时内容淡入。
    fileprivate func depart(to stage: Stage.Mark) {
        guard let window = stage.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let (source, from) = source(stage.key, in: window)
        else { return stage.landed(true) }
        Task {
            guard let image = await source.image(), stage.window === window,
                  let flight = Flight(
                    image, from: Frame(rect: from, radius: source.radius), to: Frame(rect: stage.place.rect(aspect: source.aspect ?? Flight.aspect(of: image))),
                    in: window)
            else { return stage.landed(true) }
            try? await Task.sleep(for: .seconds(Motion.moveDuration))
            // 内容在飞的那张下面露出来，那张再淡掉：两层同时一淡一显，中间会透出底色
            stage.landed(true)
            flight.dissolve()
        }
    }

    /// 要关上（`previewPresenter` 的关法都经这里）：内容当场藏起，翻到的那一份从屏上此刻的样子缩回它的缩略图（`PreviewShown`）。
    func land() {
        guard let stage, let window = stage.window else { return }
        // 先量：内容一藏，屏上的样子就量不到了
        let shown = shows[stage.key.preview]?.value?.shown(in: window) ?? .opened
        let place = stage.place
        stage.landed(false)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let (source, to) = source(stage.key, in: window) else { return }
        Task {
            let start: (Any, Frame)
            switch shown {
            case .elsewhere: return
            case .picture(let contents, let frame): start = (contents, frame)
            case .opened:
                guard let image = await source.image() else { return }
                start = (image, Frame(rect: place.rect(aspect: source.aspect ?? Flight.aspect(of: image))))
            }
            guard let flight = Flight(start.0, from: start.1, to: Frame(rect: to, radius: source.radius), in: window) else { return }
            try? await Task.sleep(for: .seconds(Motion.moveDuration))
            flight.dissolve()
        }
    }

    /// 页里能说清自己样子的视图（图片、PDF）按是哪一份登记；翻页时旧页还在淡出，按份认，不认最后登记的那个。
    func showing(_ preview: UUID, _ view: some PreviewShowing) { shows[preview] = WeakShowing(value: view) }
}

/// 页里显示内容的视图：关上那一刻自己在屏上是什么样子。
@MainActor protocol PreviewShowing: AnyObject {
    func shown(in window: NSWindow) -> PreviewShown
}

private struct WeakShowing {
    weak var value: (any PreviewShowing)?
}

extension EnvironmentValues {
    /// 缩略图在哪登记（`previewPresenter` 给）。
    @Entry var previewFlight: PreviewFlight?
}

/// 一趟：窗口最上面临时加一层图层（挂在窗口边框视图的图层上、内容视图之上：加进内容视图——SwiftUI 的托管视图——里的画不出来，实测；
/// 加的是图层不是视图，AppKit 不为它重排窗口、重算指针区域，打开那一帧少十几毫秒，实测），画面从 `from` 飞到 `to`（框与圆角），停在那里，`dissolve` 时淡掉、撤走。
@MainActor private final class Flight {
    private let layer = CALayer()

    static func aspect(of image: CGImage) -> CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }

    /// `contents` 是 CGImage 或 IOSurface；`from` 带着起点那一刻画面露出的那一截（`contentsRect`，单位坐标），飞着展开成整张。
    init?(_ contents: Any, from: Frame, to: Frame, in window: NSWindow) {
        guard let root = window.contentView?.superview, let host = root.layer else { return nil }
        layer.contents = contents
        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = window.backingScaleFactor
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        // 压过内容视图里的一切（含托管视图之后插进来的平台视图）
        layer.zPosition = 1000
        let start = root.convert(from.rect, from: nil), end = root.convert(to.rect, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = end
        layer.cornerRadius = to.radius
        layer.contentsRect = to.shown
        host.addSublayer(layer)
        layer.add(Self.move("position", NSValue(point: CGPoint(x: start.midX, y: start.midY))), forKey: "position")
        layer.add(Self.move("bounds.size", NSValue(size: start.size)), forKey: "size")
        layer.add(Self.move("cornerRadius", from.radius), forKey: "radius")
        layer.add(Self.move("contentsRect", NSValue(rect: from.shown)), forKey: "shown")
        CATransaction.commit()
    }

    /// 淡掉（`Motion.crossfade` 的时长）、撤走。
    func dissolve() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [layer] in layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.duration = Motion.crossfadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// 从 `value` 到模型值（终点），`Motion.move` 的曲线与时长（定长、不回弹，不超过 300ms）。
    private static func move(_ keyPath: String, _ value: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.duration = Motion.moveDuration
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: Float(Motion.moveCurve.0), Float(Motion.moveCurve.1), Float(Motion.moveCurve.2), Float(Motion.moveCurve.3))
        return animation
    }
}

/// 飞的一端：窗口坐标的框、圆角，与画面露出的那一截（单位坐标，整张是 0,0,1,1）。
struct PreviewFrame {
    var rect: CGRect
    var radius: CGFloat = 0
    var shown = CGRect(x: 0, y: 0, width: 1, height: 1)
}

private typealias Frame = PreviewFrame

/// 全屏页里此刻显示着的那一份能说清自己在屏上的样子时（图片放大、拖过；PDF 翻到了后面），关上时从它飞回，而不是从刚打开的样子。
enum PreviewShown {
    /// 还是打开时的样子（适合屏幕、在最前面）：飞回的起点照落地那一处（`Place`），画面用缩略图
    case opened
    /// 屏上的就是这张画面的这一截
    case picture(Any, PreviewFrame)
    /// 屏上的已不是缩略图上那一截（PDF 翻到了后面、放大了）：不飞，随浮层淡出
    case elsewhere
}

extension PreviewFlight {
    /// 全屏页内容区上飞的终点与起点：铺满内容区（含两条栏下面），`chrome` 是两条栏占的边，`key` 是翻到的那一份（跟着翻页换），
    /// `kind` 定内容落在哪（`Place`）；`landed` 是内容露没露出来（飞的这段藏着）。
    struct Stage: NSViewRepresentable {
        let flight: PreviewFlight
        let key: PreviewZoomKey
        let kind: PiPreviewKind?
        let chrome: EdgeInsets
        @Binding var landed: Bool

        func makeNSView(context: Context) -> Mark { Mark(flight: flight) }

        func updateNSView(_ mark: Mark, context: Context) {
            mark.key = key
            mark.kind = kind
            mark.chrome = chrome
            mark.landed = { landed = $0 }
        }
    }
}

extension PreviewFlight.Stage {
    final class Mark: NSView {
        fileprivate weak var flight: PreviewFlight?
        fileprivate var key = PreviewZoomKey(group: "", preview: UUID())
        fileprivate var kind: PiPreviewKind?
        fileprivate var chrome = EdgeInsets()
        fileprivate var landed: (Bool) -> Void = { _ in }
        private var departed = false

        fileprivate init(flight: PreviewFlight) {
            self.flight = flight
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { flight?.stage = self }
        }

        override func layout() {
            super.layout()
            guard !departed, window != nil, !bounds.isEmpty else { return }
            departed = true
            flight?.depart(to: self)
        }

        /// 内容落在哪（窗口坐标）：两条栏之间的那一块。
        fileprivate var place: Place {
            let area = convert(bounds, to: nil)
            return Place(kind: kind, area: CGRect(
                x: area.minX + chrome.leading, y: area.minY + chrome.bottom,
                width: area.width - chrome.leading - chrome.trailing, height: area.height - chrome.top - chrome.bottom))
        }
    }
}

/// 内容在两条栏之间的那块（`area`，窗口坐标）里落在哪：按画面比例整张放下、居中；PDF 按宽铺满、从上沿排起（`PreviewPDF`）。
private struct Place {
    let kind: PiPreviewKind?
    let area: CGRect

    func rect(aspect: CGFloat) -> CGRect {
        guard aspect > 0, area.width > 0, area.height > 0 else { return area }
        if kind == .pdf {
            let height = area.width / aspect
            return CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        }
        let width = min(area.width, area.height * aspect)
        let height = width / aspect
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
}

/// 缩略图在 `PreviewFlight` 里登记的那个不占地方的平台视图（`previewSource`）。
struct PreviewSourceMark: NSViewRepresentable {
    let flight: PreviewFlight
    let key: PreviewZoomKey
    let image: () async -> CGImage?
    let aspect: CGFloat?
    let radius: CGFloat

    func makeNSView(context: Context) -> Mark { Mark() }

    func updateNSView(_ view: Mark, context: Context) {
        if let old = view.key, old != key { flight.unregister(old, view: view) }
        view.key = key
        view.flight = flight
        flight.register(key, .init(view: view, image: image, aspect: aspect, radius: radius))
    }

    static func dismantleNSView(_ view: Mark, coordinator: ()) {
        if let key = view.key { view.flight?.unregister(key, view: view) }
    }

    final class Mark: NSView {
        var key: PreviewZoomKey?
        weak var flight: PreviewFlight?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
