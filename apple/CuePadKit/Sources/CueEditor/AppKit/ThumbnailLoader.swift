#if canImport(AppKit)
import AppKit

/// 按需提供附件要画的图：缩略图已解码就直接画；否则先画占位并在后台降采样，完成后请求重绘。
/// 解码只发生在附件被绘制时，视口外的图片不会被读取。
@MainActor
final class ThumbnailLoader {
    private unowned let textView: CueTextView
    private var inFlight = Set<URL>()
    private var failed = Set<URL>()

    init(textView: CueTextView) { self.textView = textView }

    func image(at url: URL?, size: CGSize) -> NSImage {
        let theme = textView.theme
        guard let url, !failed.contains(url) else { return placeholder(size, theme: theme, missing: true) }
        guard let thumbnail = ImageLoading.cachedThumbnail(at: url) else {
            decode(url)
            return placeholder(size, theme: theme, missing: false)
        }
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: theme.imageCornerRadius, yRadius: theme.imageCornerRadius).addClip()
            NSGraphicsContext.current?.cgContext.draw(thumbnail, in: rect)
            return true
        }
    }

    private func decode(_ url: URL) {
        guard inFlight.insert(url).inserted else { return }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { ImageLoading.thumbnail(at: url) }.value
            guard let self else { return }
            inFlight.remove(url)
            if decoded == nil { failed.insert(url) }
            textView.redrawImages(at: url)
        }
    }

    private func placeholder(_ size: CGSize, theme: CueEditorTheme, missing: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            theme.placeholderColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: theme.imageCornerRadius, yRadius: theme.imageCornerRadius).fill()
            if missing {
                let label = "图片缺失" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.dividerLabelColor]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
    }
}
#endif
