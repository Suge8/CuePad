#if os(macOS)
import AppKit
import WebKit

@MainActor final class PreviewPageShots {
    struct Shot {
        let image: CGImage
        let offset: CGRect

        func rect(in area: CGRect) -> CGRect { offset.offsetBy(dx: area.minX, dy: area.minY) }
    }

    private static let limit = 8
    private var shots: [String: Shot] = [:]
    private var order: [String] = []

    static func key(page: String, area: CGSize, dark: Bool) -> String { "\(page)|\(Int(area.width))x\(Int(area.height))|\(dark ? "dark" : "light")" }

    func shot(_ key: String) -> Shot? { shots[key] }

    func keep(_ view: WKWebView, area: CGRect, as key: String) async {
        guard shots[key] == nil, !view.isHidden, let window = view.window else { return }
        let visible = view.convert(view.bounds, to: nil).intersection(area)
        guard !visible.isEmpty else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.convert(visible, from: nil)
        guard let image = try? await view.takeSnapshot(configuration: configuration),
              let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              view.window === window, !view.isHidden
        else { return }
        shots[key] = Shot(image: picture, offset: visible.offsetBy(dx: -area.minX, dy: -area.minY))
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > Self.limit { shots[order.removeFirst()] = nil }
    }
}
#endif
