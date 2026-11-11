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
        var kind: PreviewKind?
        var page: String?
        var dark = false
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

        var shotKey: String? { page.map { PreviewPageShots.key(page: $0, area: place.area.size, dark: dark) } }

        var place: PreviewPlace {
            let area = convert(bounds, to: nil)
            return PreviewPlace(kind: kind, area: CGRect(
                x: area.minX + chrome.leading, y: area.minY + chrome.bottom,
                width: area.width - chrome.leading - chrome.trailing, height: area.height - chrome.top - chrome.bottom))
        }
    }
}

struct PreviewPlace {
    let kind: PreviewKind?
    let area: CGRect

    static func swaps(_ kind: PreviewKind?) -> Bool { [.web, .markdown, .diff].contains(kind) }

    /// 网页：快照是 `PageSnapshots.viewport` 宽排的首屏，全屏页里的网页一个 CSS 像素一点、从内容区左上排起，
    /// 快照照这个比例摆在左上、多出内容区的那截裁掉：字号、标题与第一张卡的位置同真网页，只有随宽度伸缩的块宽一点。
    /// 按内容区的宽铺满则整页缩放，落地换成真网页时字跳一号（窄窗里约 6%）。
    func frame(of image: Any, aspect: CGFloat?, crop: Alignment) -> PreviewFrame {
        guard kind == .web, area.width > 0, area.height > 0 else {
            return PreviewFrame(filling: rect(aspect: aspect ?? PreviewFrame.aspect(of: image)), with: image, crop: crop)
        }
        let page = PageSnapshots.viewport.width
        let height = page / max(PreviewFrame.aspect(of: image), 0.01)
        let width = min(area.width, page), shown = min(area.height, height)
        return PreviewFrame(
            rect: CGRect(x: area.minX, y: area.maxY - shown, width: width, height: shown),
            shown: CGRect(x: 0, y: 1 - shown / height, width: width / page, height: shown / height))
    }

    func rect(aspect: CGFloat) -> CGRect {
        guard aspect > 0, area.width > 0, area.height > 0 else { return area }
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
