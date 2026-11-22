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
    let panel: CGRect
    let area: CGRect
    let paper: CGColor?

    func cornered(_ frame: PreviewFrame) -> PreviewFrame {
        let rect = frame.rect, reach: CGFloat = 0.5
        let sides = abs(rect.minX - panel.minX) < reach || abs(rect.maxX - panel.maxX) < reach
        let ends = abs(rect.minY - panel.minY) < reach || abs(rect.maxY - panel.maxY) < reach
        guard sides, ends else { return frame }
        var frame = frame
        frame.radius = Radius.card
        return frame
    }

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

enum PreviewThumbnail {
    case picture
    case page
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
