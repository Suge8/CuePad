#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension PreviewFlight {
    /// 全屏页内容区上飞的终点与起点：铺满内容区（含两条栏下面），`chrome` 是两条栏占的边，`key` 是翻到的那一份（跟着翻页换），
    /// `kind` 定内容落在哪（`PreviewPlace`）；`waitsForPaint`：内容是本机有文件的网页，落地等它画上第一帧（`pagePainted`）；
    /// `landed` 是内容露没露出来（飞的这段藏着）；`ground` 是全屏页的底色（落地换内容时垫在快照下面）。
    struct Stage: NSViewRepresentable {
        let flight: PreviewFlight
        let key: PreviewZoomKey
        let kind: PiPreviewKind?
        let waitsForPaint: Bool
        let chrome: EdgeInsets
        @Binding var landed: Bool

        func makeNSView(context: Context) -> Mark { Mark(flight: flight) }

        func updateNSView(_ mark: Mark, context: Context) {
            mark.key = key
            mark.kind = kind
            mark.waitsForPaint = waitsForPaint
            mark.chrome = chrome
            mark.ground = context.environment.palette.desk.resolve(in: context.environment).cgColor
            mark.landed = { landed = $0 }
        }
    }
}

extension PreviewFlight.Stage {
    final class Mark: NSView {
        weak var flight: PreviewFlight?
        var key = PreviewZoomKey(group: "", preview: UUID())
        var kind: PiPreviewKind?
        var waitsForPaint = false
        var chrome = EdgeInsets()
        var ground = CGColor.clear
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

        /// 内容落在哪（窗口坐标）：两条栏之间的那一块。
        var place: PreviewPlace {
            let area = convert(bounds, to: nil)
            return PreviewPlace(kind: kind, area: CGRect(
                x: area.minX + chrome.leading, y: area.minY + chrome.bottom,
                width: area.width - chrome.leading - chrome.trailing, height: area.height - chrome.top - chrome.bottom))
        }
    }
}

/// 内容在两条栏之间的那块（`area`，窗口坐标）里落在哪：按画面比例整张放下、居中；PDF 按宽铺满、从上沿排起（`PreviewPDF`）；
/// 网页铺满整块（快照留上沿、裁掉多的，盖住真网页的整片，见 `PreviewFlight` 头注释）；Markdown 与改动的快照一比一落在正文开头。
struct PreviewPlace {
    let kind: PiPreviewKind?
    let area: CGRect

    /// 落地时换成内容、不交叉淡的几类（`PreviewFlight` 头注释）
    static func swaps(_ kind: PiPreviewKind?) -> Bool { [.web, .markdown, .diff].contains(kind) }

    func rect(aspect: CGFloat) -> CGRect {
        guard aspect > 0, area.width > 0, area.height > 0, kind != .web else { return area }
        let page = DeliverableLooks.markdownPage
        switch kind {
        // 窗口坐标 y 朝上：正文开头在 `area` 的上沿。Markdown 是居中的一栏、页边与快照的同宽；改动从左边排起，上面空一截（`PreviewDiff`）
        case .markdown: return CGRect(x: area.midX - min(area.width, PreviewContent.measure) / 2, y: area.maxY - page.height, width: page.width, height: page.height)
        case .diff: return CGRect(x: area.minX, y: area.maxY - Spacing.block - page.height, width: page.width, height: page.height)
        default: break
        }
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
