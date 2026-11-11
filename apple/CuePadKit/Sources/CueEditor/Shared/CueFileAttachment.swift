import CoreGraphics
import CueText
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 宿主告诉编辑器一个附件此刻的样子：编辑器只画，不懂同步。
public struct CueFileStatus: Equatable, Sendable {
    /// 还没到的图片写在占位上。
    public var detail: String
    public var progress: Double?

    public init(detail: String, progress: Double? = nil) {
        self.detail = detail
        self.progress = progress
    }
}

/// 点它交给宿主（`onOpenAttachment`）；牌子在绘制时现画，缩略图后台出好再重画。
final class CueFileAttachment: NSTextAttachment {
    private static let maxWidth: CGFloat = 360

    let key: String
    let name: String
    weak var core: EditorCore?

    init(key: String, name: String) {
        self.key = key
        self.name = name
        super.init(data: nil, ofType: nil)
        image = CueImageRendering.stub
    }

    required init?(coder: NSCoder) { nil }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let core = core
        let height = MainActor.assumeIsolated { core.map { FileChip.height(style: $0.style) } ?? 56 }
        return CGRect(x: 0, y: 0, width: min(Self.maxWidth, max(proposedLineFragment.width, 1)), height: height)
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> CueImage? {
        let core = core, key = key, name = name
        return MainActor.assumeIsolated { core?.fileChip(key: key, name: name, size: bounds.size) }
    }
}

/// 文件牌怎么画（两端同一份，画布由 `CueImageRendering.canvas` 给；颜色由调用方先按当前外观解析好）。
nonisolated enum FileChip {
    static let padding: CGFloat = 8
    static let thumbSide: CGFloat = 40
    private static let gap: CGFloat = 10

    static func nameFont(_ style: CueEditorTheme) -> CueFont {
        CueFont.systemFont(ofSize: style.font.pointSize - 1, weight: .medium)
    }

    static func detailFont(_ style: CueEditorTheme) -> CueFont {
        CueFont.systemFont(ofSize: (style.font.pointSize * 0.78).rounded())
    }

    static func picture(in rect: CGRect, named name: String) -> CGRect {
        guard !name.isEmpty else { return rect }
        return CGRect(x: rect.minX + padding, y: rect.midY - thumbSide / 2, width: thumbSide, height: thumbSide)
    }

    static func height(style: CueEditorTheme) -> CGFloat {
        max(thumbSide + padding * 2, ceil(line(nameFont(style)) + line(detailFont(style)) + 22))
    }

    static func draw(
        in context: CGContext, size: CGSize, name: String, status: CueFileStatus, thumbnail: CGImage?, symbol: CueImage?,
        style: CueEditorTheme
    ) {
        let rect = CGRect(origin: .zero, size: size)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: style.imageCornerRadius, cornerHeight: style.imageCornerRadius, transform: nil))
        context.setFillColor(style.imagePlaceholderColor.cgColor)
        context.fillPath()

        let box = CGRect(x: padding, y: (size.height - thumbSide) / 2, width: thumbSide, height: thumbSide)
        if let thumbnail {
            // 缩略图离牌边 `padding`，与牌的圆角同心
            let inner = max(style.imageCornerRadius - padding, 0)
            let fitted = fit(CGSize(width: thumbnail.width, height: thumbnail.height), in: box)
            context.saveGState()
            context.addPath(CGPath(roundedRect: fitted, cornerWidth: inner, cornerHeight: inner, transform: nil))
            context.clip()
            // 画布是翻过的（原点在左上），CGImage 要按图像坐标再翻一次
            context.translateBy(x: 0, y: fitted.minY * 2 + fitted.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(thumbnail, in: fitted)
            context.restoreGState()
        } else if let symbol {
            let side: CGFloat = 24
            let fitted = fit(symbol.size, in: CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side))
            symbol.draw(in: fitted)
        }

        let left = box.maxX + gap, width = max(size.width - left - padding - 4, 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameFont = nameFont(style), detailFont = detailFont(style)
        let lines = line(nameFont) + 2 + line(detailFont)
        let top = (size.height - lines) / 2
        (name as NSString).draw(
            in: CGRect(x: left, y: top, width: width, height: line(nameFont)),
            withAttributes: [.font: nameFont, .foregroundColor: style.textColor, .paragraphStyle: paragraph])
        (status.detail as NSString).draw(
            in: CGRect(x: left, y: top + line(nameFont) + 2, width: width, height: line(detailFont)),
            withAttributes: [.font: detailFont, .foregroundColor: style.markerColor, .paragraphStyle: paragraph])

        guard let progress = status.progress else { return }
        let track = CGRect(x: left, y: size.height - 7, width: width, height: 3)
        context.addPath(CGPath(roundedRect: track, cornerWidth: track.height / 2, cornerHeight: track.height / 2, transform: nil))
        context.setFillColor(style.markerColor.withAlphaComponent(0.25).cgColor)
        context.fillPath()
        let done = CGRect(x: track.minX, y: track.minY, width: max(track.height, track.width * min(max(progress, 0), 1)), height: track.height)
        context.addPath(CGPath(roundedRect: done, cornerWidth: done.height / 2, cornerHeight: done.height / 2, transform: nil))
        context.setFillColor(style.textColor.cgColor)
        context.fillPath()
    }

    private static func line(_ font: CueFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
