#if os(macOS)
import AppKit
import CueStore
import SwiftUI
import WebKit

/// 位置、尺寸与圆角都在渲染端走 `Motion.glide`（定长：飞到了才接着落内容），主线程不逐帧重排（docs/ui.md「宽屏开合」）；飞完那张画面淡掉（`Motion.fade`）。
/// 飞的这段内容藏着（`landed`），同一张图不会在两处同时出现：不用盖一层幕布——浮层淡入淡出时 SwiftUI 按层各自改透明度，半透明的幕布盖不住半透明的内容。
/// 网页落地不交叉淡：飞的是缩略图那张快照（1024 宽排的首屏），真网页按全屏页的宽排，字的位置不同，两层一淡一显就是重影。
/// 所以同样大小打开过的网页飞真网页上次画好的那一屏（`PreviewPageShots`），落在它那一处；没有时缩略图按 CSS 像素一比一落在内容区左上
/// （同真网页的起点与字号，块宽随宽度伸缩的差一点；`PreviewPlace.frame`）。落地后快照停着，等真网页载完、画上第一帧（`pagePainted`）
/// 才在同一刻露出网页、撤掉快照：全程屏上只有一层字。不让网页按快照的宽排：那样全屏页里的网页就不是它真的样子。
/// Markdown 与改动同理（缩略图是一页 360 宽的首屏，全屏页按栏宽重排）：快照按一比一落在全屏页正文开头的地方，标题与头几行字对得上，
/// 落地后同一刻换成内容（`swaps`），不交叉淡。
/// 缩略图（`previewSource`）在这里登记：画面在它的图层里、几十上百张一屏，只登记一个不占地方的平台视图，飞的那一下才取框，不给每张挂几何读数。
@MainActor final class PreviewFlight {
    struct Source {
        weak var view: NSView?
        let image: () async -> CGImage?
        let aspect: CGFloat?
        let radius: CGFloat
        let crop: PreviewCrop
    }

    private var sources: [PreviewZoomKey: Source] = [:]
    private var painted = false
    private var paintWaiter: CheckedContinuation<Void, Never>?
    private var closing = false
    private var shows: [UUID: WeakShowing] = [:]
    private let pageShots = PreviewPageShots()
    weak var stage: Stage.Mark?

    func register(_ key: PreviewZoomKey, _ source: Source) { sources[key] = source }

    func unregister(_ key: PreviewZoomKey, view: NSView) {
        if sources[key]?.view === view { sources[key] = nil }
    }

    private func source(_ key: PreviewZoomKey, in window: NSWindow) -> (Source, CGRect)? {
        guard let source = sources[key], let view = source.view, view.window === window, !view.visibleRect.isEmpty else { return nil }
        return (source, view.convert(view.bounds, to: nil))
    }

    func depart(to stage: Stage.Mark) {
        painted = false
        closing = false
        guard let window = stage.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let (source, from) = source(stage.key, in: window)
        else { return stage.landed(true) }
        let shot = stage.shotKey.flatMap { pageShots.shot($0) }
        let area = stage.place.area
        Task {
            guard let thumbnail = await source.image(), stage.window === window else { return stage.landed(true) }
            let image: Any = shot?.image ?? thumbnail
            let to = shot.map { PreviewFrame(rect: $0.rect(in: area)) }
                ?? stage.place.frame(of: thumbnail, aspect: source.aspect, crop: source.alignment)
            guard let flight = await Flight(image, from: source.frame(from, showing: image), to: to, in: window)
            else { return stage.landed(true) }
            try? await Task.sleep(for: .seconds(Motion.Glide.duration))
            guard PreviewPlace.swaps(stage.kind) else {
                // 内容在飞的那张下面露出来，那张再淡掉：两层同时一淡一显，中间会透出底色
                stage.landed(true)
                flight.dissolve()
                return
            }
            if stage.page != nil { await painted() }
            guard !closing else { return flight.remove() }
            // 快照在最上面：内容露出来的这一帧它还盖着，画上屏之后再撤，中间没有两层同时露出的一帧。
            // Markdown、改动按栏宽排、比快照宽，快照下面先垫一块桌面色铺满内容区（同此刻它四周的底），露出的那一帧正文不从快照旁边透出来
            flight.ground(stage.place.area, stage.ground)
            stage.landed(true)
            await NextFrame.drawn()
            flight.remove()
        }
    }

    func pagePainted(_ view: WKWebView? = nil) {
        painted = true
        paintWaiter?.resume()
        paintWaiter = nil
        guard let view, let stage, let key = stage.shotKey else { return }
        let area = stage.place.area
        Task { await pageShots.keep(view, area: area, as: key) }
    }

    private func painted() async {
        guard !painted else { return }
        await withCheckedContinuation { paintWaiter = $0 }
    }

    func land() {
        closing = true
        pagePainted()
        guard let stage, let window = stage.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let (source, to) = source(stage.key, in: window) else { return }
        let shown = shows[stage.key.preview]?.value?.shown(in: window) ?? .opened
        let place = stage.place
        let shot = stage.shotKey.flatMap { pageShots.shot($0) }
        Task {
            let start: (Any, Frame)
            switch shown {
            case .picture(let contents, let frame): start = (contents, frame)
            case .opened:
                if let shot { start = (shot.image, PreviewFrame(rect: shot.rect(in: place.area))); break }
                guard let image = await source.image() else { return }
                start = (image, place.frame(of: image, aspect: source.aspect, crop: source.alignment))
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

@MainActor protocol PreviewShowing: AnyObject {
    func shown(in window: NSWindow) -> PreviewShown
}

private struct WeakShowing {
    weak var value: (any PreviewShowing)?
}

extension EnvironmentValues {
    @Entry var previewFlight: PreviewFlight?
}

/// 一趟：窗口最上面临时加一层图层（挂在窗口边框视图的图层上、内容视图之上：加进内容视图——SwiftUI 的托管视图——里的画不出来，实测；
/// 加的是图层不是视图，AppKit 不为它重排窗口、重算指针区域，打开那一帧少十几毫秒，实测），画面从 `from` 飞到 `to`（框与圆角），停在那里，`dissolve` 时淡掉、撤走。
@MainActor private final class Flight {
    private let layer = CALayer()
    private weak var root: NSView?
    private var backdrop: CALayer?

    /// `contents` 是 CGImage 或 IOSurface；两端各带着那里画面露出的那一截（`contentsRect`），飞着从一截换成另一截。
    init?(_ contents: Any, from: Frame, to: Frame, in window: NSWindow) {
        guard let root = window.contentView?.superview, let host = root.layer else { return nil }
        self.root = root
        layer.contents = contents
        layer.contentsGravity = .resize
        layer.contentsScale = window.backingScaleFactor
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
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

    func ground(_ area: CGRect, _ color: CGColor) {
        guard let root, let host = root.layer else { return }
        let backdrop = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = root.convert(area, from: nil)
        backdrop.backgroundColor = color
        backdrop.zPosition = layer.zPosition - 1
        host.addSublayer(backdrop)
        CATransaction.commit()
        self.backdrop = backdrop
    }

    func remove() {
        layer.removeFromSuperlayer()
        backdrop?.removeFromSuperlayer()
    }

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

    private static func move(_ keyPath: String, _ value: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.duration = Motion.Glide.duration
        animation.timingFunction = Motion.Glide.timing
        return animation
    }
}

extension PreviewFlight.Source {
    var alignment: Alignment {
        if case .aligned(let alignment) = crop { alignment } else { .center }
    }

    /// 点名图露的是细节最多的那块，按缩略图同一个算法在整张上算；`contents` 是全屏页的大图（IOSurface）时到缩略图交的整张上算，单位坐标一样。
    func frame(_ rect: CGRect, showing contents: Any) async -> PreviewFrame {
        guard case .detail = crop else { return PreviewFrame(filling: rect, radius: radius, with: contents, crop: alignment) }
        let whole: CGImage? = if contents is IOSurface { await image() } else { (contents as! CGImage) }
        guard let whole, whole.width > 0, whole.height > 0 else { return PreviewFrame(filling: rect, radius: radius, with: contents, crop: .center) }
        let region = await DeliverableLooks.detailRegion(whole, aspect: rect.width / max(rect.height, 1))
        let width = CGFloat(whole.width), height = CGFloat(whole.height)
        return PreviewFrame(rect: rect, radius: radius, shown: CGRect(
            x: region.minX / width, y: 1 - region.maxY / height, width: region.width / width, height: region.height / height))
    }
}

struct PreviewFrame {
    var rect: CGRect
    var radius: CGFloat = 0
    var shown = CGRect(x: 0, y: 0, width: 1, height: 1)

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

    private static func share(_ low: Bool, _ high: Bool) -> CGFloat { low ? 0 : high ? 1 : 0.5 }

    static func aspect(of contents: Any) -> CGFloat {
        let (width, height) = if let surface = contents as? IOSurface { (surface.width, surface.height) }
            else { ((contents as! CGImage).width, (contents as! CGImage).height) }
        return CGFloat(width) / CGFloat(max(height, 1))
    }
}

private typealias Frame = PreviewFrame

enum PreviewShown {
    case opened
    case picture(Any, PreviewFrame)
}
#endif
