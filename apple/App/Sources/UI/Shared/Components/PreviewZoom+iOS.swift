#if os(iOS)
import CueEditor
import SwiftUI
import UIKit

/// "放大着没有"只有滚动区自己的 `zoomScale` 一个来源：翻页、关闭的手势都直接看手指下的它（`PreviewDismissGuard`），不另存一份。
/// 解好之前先铺缩略图的画面（`look`，飞出来的第一帧就有图）；先解一张够铺满屏幕的；第一次放大后停下来（松手、回弹完、双击放大完）才解更清楚的一张，解好且不在动时换上，留到这一页被拆掉：
/// 大图解码与上传纹理几十毫秒，放在手势中间会让那几帧卡住（模拟器上解码还会抢渲染的 CPU）；只看不放大的图不解大的。
struct PreviewImage: UIViewRepresentable {
    let file: URL
    let look: PreviewLook?
    @Environment(\.previewInsets) private var insets
    @Environment(\.displayScale) private var scale

    func makeUIView(context: Context) -> PreviewZoomView { PreviewZoomView(file: file, scale: scale, look: look) }

    func updateUIView(_ view: PreviewZoomView, context: Context) {
        view.frameInsets = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
    }

    static func dismantleUIView(_ view: PreviewZoomView, coordinator: ()) { view.cancel() }
}

final class PreviewZoomView: UIScrollView, UIScrollViewDelegate {
    nonisolated private static let maxZoom: CGFloat = 5

    var frameInsets: UIEdgeInsets = .zero { didSet { if frameInsets != oldValue { setNeedsLayout() } } }

    private let file: URL
    private let scale: CGFloat
    private let imageView = UIImageView()
    private var loading: Task<Void, Never>?
    private var detailing: Task<Void, Never>?
    private var pending: UIImage?
    private var aspect: CGFloat?
    private var decoded: UIImage?
    // 重算只看框与比例：换清晰度不算
    private var fitted: CGSize = .zero
    private var fittedFor: (area: CGSize, aspect: CGFloat)?

    init(file: URL, scale: CGFloat, look: PreviewLook?) {
        self.file = file
        self.scale = scale
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = Self.maxZoom
        // 栏后面不垫系统的滚动边缘效果
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
        imageView.isAccessibilityElement = false
        // 缩略图按整像素缩，比例与图差一点：照图的比例铺满它的框
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        aspect = Thumbnails.pointSize(at: file).flatMap { $0.height > 0 ? $0.width / $0.height : nil }
        if let now = look?.now { cover(now) } else if let look {
            Task { [weak self] in if let look = await look.load() { self?.cover(look) } }
        }
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func cancel() {
        loading?.cancel()
        detailing?.cancel()
    }

    var zoomedIn: Bool { zoomScale > minimumZoomScale + 0.01 }

    override func layoutSubviews() {
        super.layoutSubviews()
        if loading == nil, !bounds.isEmpty { loading = load(Self.screenPixels(bounds.size, scale)) { [weak self] in self?.show($0) } }
        let area = bounds.inset(by: frameInsets).size
        guard let aspect, area.width > 0, area.height > 0, fittedFor.map({ $0.area != area || $0.aspect != aspect }) ?? true else { return }
        fittedFor = (area, aspect)
        fitted = area.width / area.height > aspect
            ? CGSize(width: area.height * aspect, height: area.height) : CGSize(width: area.width, height: area.width / aspect)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private static func screenPixels(_ size: CGSize, _ scale: CGFloat) -> @Sendable (CGSize) -> Int {
        let pixels = Int(max(size.width, size.height) * scale)
        return { min(Int(max($0.width, $0.height)), pixels) }
    }

    private func center() {
        let area = bounds.inset(by: frameInsets).size
        let dx = max(0, (area.width - contentSize.width) / 2), dy = max(0, (area.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: frameInsets.top + dy, left: frameInsets.left + dx, bottom: frameInsets.bottom + dy, right: frameInsets.right + dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { settle() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }

    private var moving: Bool { isZooming || isZoomBouncing || isTracking || isDecelerating }

    private func settle() {
        if let pending {
            self.pending = nil
            show(pending)
        }
        guard zoomedIn, detailing == nil else { return }
        let fit = max(fitted.width, fitted.height) * scale
        detailing = load({ PreviewScale.detailPixels(fit: fit, most: Self.maxZoom, original: $0) }) { [weak self] in self?.show($0) }
    }

    private func cover(_ look: PreviewSources.Look) {
        guard decoded == nil else { return }
        if aspect == nil { aspect = look.aspect }
        imageView.image = UIImage(cgImage: look.image)
        setNeedsLayout()
    }

    /// 清楚的到了以后不再换回铺满屏幕的那张；在动时等停下来再换上。
    private func show(_ image: UIImage) {
        guard !(decoded.map { $0.size.width >= image.size.width } ?? false) else { return }
        guard !moving else {
            pending = image
            return
        }
        decoded = image
        imageView.image = image
        // 文件头读不到比例时以解出来的为准（同一张图的几种清晰度比例一样，只有第一张会改它）
        if aspect == nil { aspect = image.size.width / max(image.size.height, 1) }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 动画用滚动区自己的（与捏合松手后的回弹同一条）：换成 `UIView.animate(Motion.nudge)` 驱动缩放时每次双击都掉两三帧（模拟器逐帧录屏实测），系统的一帧不掉。
    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if zoomedIn { return setZoomScale(1, animated: true) }
        let area = bounds.inset(by: frameInsets).size
        let fill = max(area.width / fitted.width, area.height / fitted.height)
        let target = min(max(PreviewScale.tap, fill), maximumZoomScale)
        let point = tap.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    private func load(_ longestSide: @escaping @Sendable (CGSize) -> Int, loaded: @escaping (UIImage) -> Void) -> Task<Void, Never> {
        let file = file
        return Task {
            guard let image = await Self.decode(file, longestSide: longestSide), !Task.isCancelled else { return }
            loaded(UIImage(cgImage: image))
        }
    }

    @concurrent private static func decode(_ file: URL, longestSide: @escaping @Sendable (CGSize) -> Int) async -> CGImage? {
        Thumbnails.decoded(at: file, longestSide: longestSide)
    }
}
#endif
