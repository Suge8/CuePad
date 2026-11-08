#if os(macOS)
import AppKit
import WebKit

/// Mac 全屏页里真网页的那一屏：真网页画上第一帧后，从网页视图上按内容区截一张（`keep`），按网页、内容区大小与深浅色记下。
/// 下次同样大小打开同一页，飞的就是它、落在它截下来的那一处（`shot`），落地换成真网页时字与块一点不动。
/// 缩略图是 1024 宽排的首屏，全屏页的网页按内容区的宽排：块宽随宽度伸缩的页面（多数），两种排法的块位置对不上，所以要同宽的这一张。
/// 截的是已经上屏的网页，不另起网页进程；第一次打开（或窗口改了大小）还没有，退回缩略图一比一的摆法（`PreviewPlace.frame`），打开不等它。
@MainActor final class PreviewPageShots {
    struct Shot {
        let image: CGImage
        /// 在窗口里的框，相对内容区左下角（窗口坐标 y 朝上）
        let offset: CGRect

        func rect(in area: CGRect) -> CGRect { offset.offsetBy(dx: area.minX, dy: area.minY) }
    }

    /// 记几张：一份网页一种窗口大小一张，几 MB 一张
    private static let limit = 8
    private var shots: [String: Shot] = [:]
    private var order: [String] = []

    /// `page` 是网页的附件键（内容哈希 + 文件名）
    static func key(page: String, area: CGSize, dark: Bool) -> String { "\(page)|\(Int(area.width))x\(Int(area.height))|\(dark ? "dark" : "light")" }

    func shot(_ key: String) -> Shot? { shots[key] }

    /// 截 `view` 落在内容区 `area`（窗口坐标）里的那一截。载不出来、藏起来的不截。
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
