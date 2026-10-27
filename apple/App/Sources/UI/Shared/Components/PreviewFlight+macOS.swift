#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// Mac 全屏预览的飞出、飞回（iOS 是系统的 zoom 转场）：打开时点的那张缩略图从原处长到内容落下的地方，关上时翻到的那一份缩回它自己的缩略图
/// （那张不在屏上时只随浮层淡出）。飞的是缩略图的那张画面，一层 Core Animation 图层浮在整窗最上面，位置、尺寸与圆角都在渲染端走 `Motion.glide`
/// （定长：飞到了才接着落内容），主线程不逐帧重排（docs/layout.md「Mac 上开合不逐帧挪位置」）；飞完那张画面淡掉（`Motion.fade`）。
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
        let crop: PreviewCrop
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
                  let flight = await Flight(
                    image, from: source.frame(from, showing: image),
                    to: Frame(filling: stage.place.rect(aspect: source.aspect ?? Frame.aspect(of: image)), with: image, crop: source.alignment),
                    in: window)
            else { return stage.landed(true) }
            try? await Task.sleep(for: .seconds(Motion.Glide.duration))
            // 内容在飞的那张下面露出来，那张再淡掉：两层同时一淡一显，中间会透出底色
            stage.landed(true)
            flight.dissolve()
        }
    }

    /// 要关上（`previewPresenter` 的关法都经这里）：翻到的那一份从屏上此刻的样子（`PreviewShown`）缩回它的缩略图；
    /// 飞的那层铺上时才藏内容，没得飞（缩略图不在屏上、减弱动态效果）就留着内容随浮层淡出。
    func land() {
        guard let stage, let window = stage.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let (source, to) = source(stage.key, in: window) else { return }
        let shown = shows[stage.key.preview]?.value?.shown(in: window) ?? .opened
        let place = stage.place
        Task {
            let start: (Any, Frame)
            switch shown {
            case .picture(let contents, let frame): start = (contents, frame)
            case .opened:
                guard let image = await source.image() else { return }
                start = (image, Frame(filling: place.rect(aspect: source.aspect ?? Frame.aspect(of: image)), with: image, crop: source.alignment))
            }
            guard let flight = await Flight(start.0, from: start.1, to: source.frame(to, showing: start.0), in: window) else { return }
            stage.landed(false)
            try? await Task.sleep(for: .seconds(Motion.Glide.duration))
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

    /// `contents` 是 CGImage 或 IOSurface；两端各带着那里画面露出的那一截（`contentsRect`），飞着从一截换成另一截。
    init?(_ contents: Any, from: Frame, to: Frame, in window: NSWindow) {
        guard let root = window.contentView?.superview, let host = root.layer else { return nil }
        layer.contents = contents
        // 露出哪一截全由两端的 `shown` 定（缩略图怎么裁、对齐哪边由它登记时交出），图层不再自己居中裁
        layer.contentsGravity = .resize
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

    /// 淡掉（`Motion.fade`）、撤走。
    func dissolve() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [layer] in layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.duration = Motion.Fade.duration
        fade.timingFunction = Motion.Fade.timing
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// 从 `value` 到模型值（终点），`Motion.glide`。
    private static func move(_ keyPath: String, _ value: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.duration = Motion.Glide.duration
        animation.timingFunction = Motion.Glide.timing
        return animation
    }
}

extension PreviewFlight.Source {
    /// 内容那一端多出来的按什么留：点名图在那一端是整张、不裁，居中即可。
    var alignment: Alignment {
        if case .aligned(let alignment) = crop { alignment } else { .center }
    }

    /// 缩略图这一端：框 `rect`，画面 `contents` 露出缩略图上那一截（`crop`）。
    /// 点名图露的是细节最多的那块，按缩略图同一个算法在整张上算；`contents` 是全屏页的大图（IOSurface）时到缩略图交的整张上算，单位坐标一样。
    func frame(_ rect: CGRect, showing contents: Any) async -> PreviewFrame {
        guard case .detail = crop else { return PreviewFrame(filling: rect, radius: radius, with: contents, crop: alignment) }
        let whole: CGImage? = if contents is IOSurface { await image() } else { (contents as! CGImage) }
        guard let whole, whole.width > 0, whole.height > 0 else { return PreviewFrame(filling: rect, radius: radius, with: contents, crop: .center) }
        let region = await DeliverableLooks.detailRegion(whole, aspect: rect.width / max(rect.height, 1))
        let width = CGFloat(whole.width), height = CGFloat(whole.height)
        // 像素原点左上，单位坐标 y 朝上
        return PreviewFrame(rect: rect, radius: radius, shown: CGRect(
            x: region.minX / width, y: 1 - region.maxY / height, width: region.width / width, height: region.height / height))
    }
}

/// 飞的一端：窗口坐标的框、圆角，与画面露出的那一截（单位坐标，整张是 0,0,1,1，y 朝上）。
struct PreviewFrame {
    var rect: CGRect
    var radius: CGFloat = 0
    var shown = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 画面铺满 `rect`、多出来的按 `crop` 那边留（同缩略图的裁法：截图留上沿）。
    init(filling rect: CGRect, radius: CGFloat = 0, with contents: Any, crop: Alignment) {
        self.rect = rect
        self.radius = radius
        let picture = Self.aspect(of: contents), box = rect.width / max(rect.height, 1)
        guard picture > 0, box > 0 else { return }
        if picture > box {
            let width = box / picture
            shown = CGRect(x: (1 - width) * Self.share(crop.horizontal == .leading, crop.horizontal == .trailing), y: 0, width: width, height: 1)
        } else {
            let height = picture / box
            shown = CGRect(x: 0, y: (1 - height) * Self.share(crop.vertical == .bottom, crop.vertical == .top), width: 1, height: height)
        }
    }

    init(rect: CGRect, radius: CGFloat = 0, shown: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.rect = rect
        self.radius = radius
        self.shown = shown
    }

    /// 多出来的那段裁在低端（左、下）的份额：留低端 0、留高端 1、居中一半。
    private static func share(_ low: Bool, _ high: Bool) -> CGFloat { low ? 0 : high ? 1 : 0.5 }

    /// 图层上放的画面（IOSurface 或 CGImage）的宽高比。
    static func aspect(of contents: Any) -> CGFloat {
        let (width, height) = if let surface = contents as? IOSurface { (surface.width, surface.height) }
            else { ((contents as! CGImage).width, (contents as! CGImage).height) }
        return CGFloat(width) / CGFloat(max(height, 1))
    }
}

private typealias Frame = PreviewFrame

/// 全屏页里此刻显示着的那一份在屏上的样子，关上时从它飞回，而不是从刚打开的样子。
enum PreviewShown {
    /// 说不清（内容还没出来、不是图片或 PDF）：飞回的起点照落地那一处（`Place`），画面用缩略图
    case opened
    /// 屏上的就是这张画面（的这一截）
    case picture(Any, PreviewFrame)
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
    let crop: PreviewCrop

    func makeNSView(context: Context) -> Mark { Mark() }

    func updateNSView(_ view: Mark, context: Context) {
        if let old = view.key, old != key { flight.unregister(old, view: view) }
        view.key = key
        view.flight = flight
        flight.register(key, .init(view: view, image: image, aspect: aspect, radius: radius, crop: crop))
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
