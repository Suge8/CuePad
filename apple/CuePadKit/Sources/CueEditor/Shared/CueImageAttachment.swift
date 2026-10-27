import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 内联图片附件。只保存键与文件位置；尺寸只读文件头，像素在附件被绘制（进入视口）时才由
/// `ThumbnailLoader` 降采样解码。
///
/// 这里不用 NSTextAttachmentViewProvider：TextKit（macOS）不保证首次布局后加载视图，视图还会吞掉点击、
/// 遮住选区高亮。附件带一张 1×1 占位图只是为了让 TextKit 走 `image(for:…)` 绘制路径，真图在那里按需提供。
final class CueImageAttachment: NSTextAttachment {
    private static let placeholderSize = CGSize(width: 240, height: 120)

    let key: String
    /// 本机那份；还没从 iCloud 取来为 nil，到了由 `relocate` 补上。
    private(set) var fileURL: URL?
    weak var core: EditorCore?
    private lazy var pointSize: CGSize? = fileURL.flatMap(Thumbnails.pointSize(at:))

    init(key: String, fileURL: URL?) {
        self.key = key
        self.fileURL = fileURL
        super.init(data: nil, ofType: nil)
        image = CueImageRendering.stub
    }

    required init?(coder: NSCoder) { nil }

    /// 文件到了（`EditorCore.refreshAttachments`）：本来缺着的换成本机那份，尺寸重读。还没到的也要重画（占位上写着传了几成）。
    func relocate(_ url: URL?) -> Bool {
        guard fileURL == nil else { return false }
        if let url {
            fileURL = url
            pointSize = Thumbnails.pointSize(at: url)
        }
        return true
    }

    /// 宽度自适应：不超过行宽，也不放大超过自然尺寸；文件缺失时用固定占位尺寸。
    func size(fitting width: CGFloat) -> CGSize {
        let available = max(width, 1)
        guard let natural = pointSize else {
            return CGSize(width: min(Self.placeholderSize.width, available), height: Self.placeholderSize.height)
        }
        let fitted = min(natural.width, available)
        return CGSize(width: fitted, height: fitted * natural.height / natural.width)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        CGRect(origin: .zero, size: size(fitting: proposedLineFragment.width))
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> CueImage? {
        let core = core, url = fileURL, key = key
        return MainActor.assumeIsolated {
            guard let core else { return nil }
            guard let url else { return CueImageRendering.placeholder(size: bounds.size, style: core.style, label: core.missingImageLabel(key)) }
            return core.thumbnails.image(at: url, size: bounds.size)
        }
    }
}
