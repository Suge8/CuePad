#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension PreviewFlight {
    struct Stage: NSViewRepresentable {
        let flight: PreviewFlight
        let key: PreviewZoomKey
        let kind: PreviewKind?
        let page: String?
        let chrome: EdgeInsets
        @Binding var landed: Bool

        func makeNSView(context: Context) -> Mark { Mark(flight: flight) }

        func updateNSView(_ mark: Mark, context: Context) {
            mark.key = key
            mark.kind = kind
            mark.page = page
            mark.dark = context.environment.colorScheme == .dark
            mark.paper = NSColor(context.environment.palette.paper).cgColor
            mark.chrome = chrome
            mark.landed = { landed = $0 }
        }
    }
}

extension PreviewFlight.Stage {
    final class Mark: NSView {
        weak var flight: PreviewFlight?
        var key = PreviewZoomKey(group: "", preview: UUID())
        var kind: PreviewKind?
        var page: String?
        var dark = false
        var paper: CGColor?
        var chrome = EdgeInsets()
        var landed: (Bool) -> Void = { _ in }
        private var departed = false

        init(flight: PreviewFlight) {
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

        var shotKey: String? { page.map { PreviewPageShots.key(page: $0, area: place.area.size, dark: dark) } }

        var place: PreviewPlace {
            let area = convert(bounds, to: nil)
            return PreviewPlace(kind: kind, panel: area, area: CGRect(
                x: area.minX + chrome.leading, y: area.minY + chrome.bottom,
                width: area.width - chrome.leading - chrome.trailing, height: area.height - chrome.top - chrome.bottom), paper: paper)
        }
    }
}

struct PreviewPlace {
    let kind: PreviewKind?
    /// 全屏页那张卡的框。
    let panel: CGRect
    let area: CGRect
    /// 自己排的那几类铺的纸色（`PreviewContent`）。
    let paper: CGColor?

    /// 贴到卡角上的画面（铺满的图片、网页）照卡的圆角切：飞的那张盖在卡上面，不切的话停着是直角，化掉露出内容才变圆。
    func cornered(_ frame: PreviewFrame) -> PreviewFrame {
        let rect = frame.rect, reach: CGFloat = 0.5
        let sides = abs(rect.minX - panel.minX) < reach || abs(rect.maxX - panel.maxX) < reach
        let ends = abs(rect.minY - panel.minY) < reach || abs(rect.maxY - panel.maxY) < reach
        guard sides, ends else { return frame }
        var frame = frame
        frame.radius = Radius.card
        return frame
    }

    /// 缩略图是另一种宽度排的首屏的那几种，飞到了要淡成真内容（`PreviewFlight.depart`），所以落在淡过去时字对得上的地方：
    /// - 网页（`PageSnapshots.viewport` 宽的首屏）按内容区的宽铺满、从顶上排起、多出的那截裁掉：居中的一栏（多数页面）落在真网页同一处，
    ///   只是字大一点（内容区 960 宽时 6%）。否决：照 CSS 像素一比一摆在左上——居中的内容横着差半个宽度差，落地时整块横跳。
    /// - Markdown 与改动（`DeliverableLooks.markdownPage` 那一小页）：纸长成整个内容区，字照原大小停在正文开头那里（`page`），与真内容的头几行叠得上。
    ///   否决：只飞那一小页——停在全屏页一角，提前化掉又成了内容凭空闪出来；把小页拉到内容区那么宽——字大了近三倍，淡过去时两层字差着个头。
    func frame(of image: Any, aspect: CGFloat?, crop: Alignment) -> PreviewFrame {
        guard kind.thumbnail != .picture, area.width > 0, area.height > 0 else {
            return PreviewFrame(filling: rect(aspect: aspect ?? PreviewFrame.aspect(of: image)), with: image, crop: crop)
        }
        if let page {
            var frame = PreviewFrame(filling: page, with: image, crop: crop)
            frame.page = page
            frame.paper = paper
            frame.rect = area
            return frame
        }
        let height = area.width / max(PreviewFrame.aspect(of: image), 0.01), shown = min(area.height, height)
        return PreviewFrame(
            rect: CGRect(x: area.minX, y: area.maxY - shown, width: area.width, height: shown),
            shown: CGRect(x: 0, y: 1 - shown / height, width: 1, height: shown / height))
    }

    /// 窗口坐标 y 朝上：正文开头在 `area` 的上沿。Markdown 是居中的一栏、页边与快照的同宽；改动从左边排起，上面空一截（`PreviewDiff`）。
    private var page: CGRect? {
        let page = DeliverableLooks.markdownPage
        return switch kind {
        case .markdown: CGRect(x: area.midX - min(area.width, PreviewContent.measure) / 2, y: area.maxY - page.height, width: page.width, height: page.height)
        case .diff: CGRect(x: area.minX, y: area.maxY - Spacing.block - page.height, width: page.width, height: page.height)
        default: nil
        }
    }

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

/// 缩略图上画的与全屏页是什么关系，定怎么飞（`PreviewFlight`）、落在哪（`PreviewPlace.frame`）。
enum PreviewThumbnail {
    /// 同一张画面（图片、PDF 的页、视频的一帧）：飞到了，内容在它底下当场换上。
    case picture
    /// 自己排的一小页纸（Markdown、改动），全屏页按栏宽另排：纸长成整页，字淡成真内容。
    case page
    /// 网页的首屏：停着等真网页画好再淡过去。
    case screen
}

extension PreviewKind? {
    var thumbnail: PreviewThumbnail {
        switch self {
        case .web: .screen
        case .markdown, .diff: .page
        default: .picture
        }
    }
}

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
