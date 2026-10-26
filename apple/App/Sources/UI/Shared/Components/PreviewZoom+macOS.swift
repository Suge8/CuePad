#if os(macOS)
import AppKit
import CoreVideo
import CueEditor
import IOSurface

/// 全屏页里的一张图（Mac）：放大多少只有滚动视图自己的 `magnification` 一份，翻页、顶栏都不另记。
/// - 适合屏幕是 1 倍：整张放在两条栏之间（`chrome`）、居中；放大后铺到栏下面，拖到哪都看得到边角。
/// - 触控板捏合以指尖处为中心、跟手，捏过头（小过适合屏幕、大过上限）有橡皮筋回弹；放大后双指滑动看图，滑到边有回弹：都是系统滚动视图的。
/// - 捏完离适合屏幕不到一成就回到适合屏幕（`snap`，在 `settle` 里）。
/// - 双击、智能缩放（双指轻点两下）在适合屏幕与放大（`PreviewScale.tap` 倍，至多到上限）之间切，放大到点的那一处，走 `Motion.move` 的曲线。
/// - 放大后按住拖动看图（同"预览"的移动）。
/// - 横扫翻不翻页由全屏页按这张往那边还滑不滑得动定（`PageInput`）：没放大、或放大了已滑到那一边才翻。
/// 解码都在后台，与手机同一套：打开时只按全屏页的大小解一份（进缩略图缓存，再打开不再解）；第一次放大停下来才解清楚的那张
/// （`PreviewScale.detailPixels`，不进缓存），停稳了才换上（捏着、滑着、动画途中到了先留着）。只看不放大的图不解原图。
final class PreviewZoom: NSScrollView, PreviewShowing {
    /// 两条栏占的边：适合屏幕时整张让在它们之间。
    var chrome = NSEdgeInsetsZero {
        didSet {
            guard chrome.top != oldValue.top || chrome.bottom != oldValue.bottom || chrome.left != oldValue.left || chrome.right != oldValue.right else { return }
            contentInsets = chrome
            fit()
        }
    }

    private let canvas = Canvas()
    private let file: URL
    /// 原图的像素尺寸（读文件头）：定比例与能放大到多少，换清晰度不变
    private var original: CGSize = .zero
    /// 清楚的那张：在解或解好了
    private var detailing: Task<Void, Never>?
    /// 捏着、滑着、动画途中到了的那张，停下来再换上
    private var pending: Picture?
    private var moving = false

    init(file: URL) {
        self.file = file
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false
        allowsMagnification = true
        minMagnification = 1
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .allowed
        contentView = Clip()
        documentView = canvas
        canvas.zoom = self
        let center = NotificationCenter.default
        for name in [NSScrollView.willStartLiveMagnifyNotification, NSScrollView.willStartLiveScrollNotification] {
            center.addObserver(self, selector: #selector(started), name: name, object: self)
        }
        for name in [NSScrollView.didEndLiveMagnifyNotification, NSScrollView.didEndLiveScrollNotification] {
            center.addObserver(self, selector: #selector(settle), name: name, object: self)
        }
        Task { await load() }
    }

    required init?(coder: NSCoder) { nil }

    /// 放大了：拖动是看图。
    var zoomed: Bool { magnification > 1.001 }

    private func load() async {
        let fitPixels = Int(max(PanelStyle.previewSize.width, PanelStyle.previewSize.height) * (window?.backingScaleFactor ?? 2))
        guard let (first, original) = await Self.open(file, longest: fitPixels) else { return }
        self.original = original
        show(first)
    }

    @objc private func started() { moving = true }

    /// 停下来了（捏完、滑完、动画走完、拖完）：先换上途中到了的那张；放大着、还没有清楚的那张就开始解。
    /// 捏完离适合屏幕不到 `snap` 就回到适合屏幕（同"照片"）：差一点点的放大看着就是适合屏幕，双击却会当成放大了、缩回去。
    /// 在捏完（滚动视图自己的回弹也走完）这里判，不在松手那一下：捏过头缩小时松手那一刻还小于 1，回弹却停在 1 之上一点（实测 1.04）。
    @objc fileprivate func settle() {
        moving = false
        if zoomed, magnification < 1 + Self.snap { return animate(to: 1, at: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
        if let pending {
            self.pending = nil
            show(pending)
        }
        guard zoomed, detailing == nil, original.width > 0 else { return }
        let fit = max(canvas.frame.width, canvas.frame.height) * (window?.backingScaleFactor ?? 2)
        let longest = PreviewScale.detailPixels(fit: fit, most: maxMagnification, original: original)
        // 适合屏幕解的那张已经够大（小图）就不再解
        guard CGFloat(longest) > max(canvas.layerPixels.width, canvas.layerPixels.height) else { return }
        detailing = Task { [weak self, file] in
            guard let picture = await Self.decode(file, longest: longest), let self else { return }
            if moving { pending = picture } else { show(picture) }
        }
    }

    private func show(_ picture: Picture) {
        canvas.layerPixels = picture.pixels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.layer?.contents = picture.surface
        CATransaction.commit()
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// 按此刻的大小摆成适合屏幕（1 倍）的那一张，放大了的照旧按比例放大。
    private func fit() {
        let area = CGSize(width: bounds.width - chrome.left - chrome.right, height: bounds.height - chrome.top - chrome.bottom)
        let pixels = original
        guard pixels.width > 0, pixels.height > 0, area.width > 0, area.height > 0 else { return }
        let scale = min(area.width / pixels.width, area.height / pixels.height)
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        // 上限：至少放大到 `PreviewScale.tap`，原图像素多的放大到一个像素占两个屏幕像素。没变不重设：捏过头回弹的途中每帧都排一次，
        // 重设上下限会打断回弹、停在半路
        let most = max(PreviewScale.tap, 2 * pixels.width / (size.width * (window?.backingScaleFactor ?? 2)))
        if maxMagnification != most { maxMagnification = most }
        guard canvas.frame.size != size else { return }
        canvas.frame.size = size
    }

    /// 双击、智能缩放：在适合屏幕与放大之间切，放大到 `point`（画面坐标）那一处。
    func toggle(at point: NSPoint) {
        animate(to: zoomed ? 1 : min(PreviewScale.tap, maxMagnification), at: point)
    }

    private func animate(to target: CGFloat, at point: NSPoint) {
        moving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.moveDuration
            context.timingFunction = Motion.moveTiming
            animator().setMagnification(target, centeredAt: point)
        } completionHandler: { [weak self] in
            self?.settle()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        toggle(at: canvas.convert(event.locationInWindow, from: nil))
    }

    /// 关上那一刻屏上的样子：画面在窗口里露出的那一块（放大了只是它在滚动视图里看得见的那截），与它是整张图的哪一截。
    func shown(in window: NSWindow) -> PreviewShown {
        let picture = canvas.convert(canvas.bounds, to: nil), visible = picture.intersection(convert(bounds, to: nil))
        guard let contents = canvas.layer?.contents, !visible.isEmpty else { return .opened }
        // 单位坐标的 y 与窗口一样朝上
        let shown = CGRect(
            x: (visible.minX - picture.minX) / picture.width, y: (visible.minY - picture.minY) / picture.height,
            width: visible.width / picture.width, height: visible.height / picture.height)
        return .picture(contents, PreviewFrame(rect: visible, shown: shown))
    }

    /// 放大后按住拖动：可见区跟着指针反向挪，夹在能滑到的范围里。
    fileprivate func pan(by delta: CGSize) {
        let clip = contentView
        var bounds = clip.bounds
        bounds.origin.x -= delta.width / magnification
        bounds.origin.y -= delta.height / magnification
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clip)
    }

    /// 解好、画进一块 IOSurface 的图：图层直接显示它，提交时只交过去一个句柄。直接交 CGImage 的话，提交那一下主线程要把整张位图拷给渲染端，
    /// 一张 2400 万像素的原图（96MB）就是 70～80ms 的一帧（实测）。
    private struct Picture: @unchecked Sendable {
        let surface: IOSurface
        let pixels: CGSize
    }

    /// 打开时那一张（进缩略图缓存）与原图的像素尺寸。
    @concurrent private static func open(_ file: URL, longest: Int) async -> (Picture, CGSize)? {
        guard let image = Thumbnails.image(at: file, maxPixel: longest), let surface = surface(of: image) else { return nil }
        let pixels = CGSize(width: image.width, height: image.height)
        return (Picture(surface: surface, pixels: pixels), Thumbnails.pixelSize(at: file) ?? pixels)
    }

    /// 清楚的那张（不进缩略图缓存：一张就几十上百兆）。
    @concurrent private static func decode(_ file: URL, longest: Int) async -> Picture? {
        guard let image = Thumbnails.decoded(at: file, longestSide: { _ in longest }), let surface = surface(of: image) else { return nil }
        return Picture(surface: surface, pixels: CGSize(width: image.width, height: image.height))
    }

    nonisolated private static func surface(of image: CGImage) -> IOSurface? {
        let width = image.width, height = image.height, rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: rowBytes, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 渲染端按这块的色彩空间显示（不写就当 sRGB，广色域的图会发灰）
        if let space = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space) }
        return surface
    }

    /// 捏完比适合屏幕大不到这么多（一成）算回到适合屏幕
    private static let snap: CGFloat = 0.1
}

/// 画面：图层直接显示解好的图（不经 `NSImageView` 再画一遍），翻转坐标（左上为原点）。
private final class Canvas: NSView {
    weak var zoom: PreviewZoom?
    /// 图层上那张的像素尺寸
    var layerPixels: CGSize = .zero
    private var dragged: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    /// 窗口不在前台时第一下也算（双击放大不用先点一下激活）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return zoom?.toggle(at: convert(event.locationInWindow, from: nil)) ?? () }
        dragged = zoom?.zoomed == true ? event.locationInWindow : nil
        if dragged != nil { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragged else { return }
        let now = event.locationInWindow
        // 窗口坐标 y 朝上，画面翻转（y 朝下）
        zoom?.pan(by: CGSize(width: now.x - last.x, height: last.y - now.y))
        dragged = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragged != nil {
            NSCursor.pop()
            zoom?.settle()
        }
        dragged = nil
    }
}

/// 画面小过可见区的那一向居中（滚动视图默认贴左上），大过的照常夹在能滑到的范围里（含滑到边的回弹）。
private final class Clip: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView?.frame, let scroll = enclosingScrollView else { return rect }
        let insets = scroll.contentInsets, scale = scroll.magnification
        let width = rect.width - (insets.left + insets.right) / scale, height = rect.height - (insets.top + insets.bottom) / scale
        if document.width < width { rect.origin.x = document.midX - width / 2 - insets.left / scale }
        if document.height < height { rect.origin.y = document.midY - height / 2 - insets.top / scale }
        return rect
    }
}
#endif
