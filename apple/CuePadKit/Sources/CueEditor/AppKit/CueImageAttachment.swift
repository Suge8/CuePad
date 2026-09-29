#if canImport(AppKit)
import AppKit

/// 内联图片附件。只保存 id 与文件位置；尺寸只读文件头，像素在附件被绘制（进入视口）时才由
/// `ThumbnailLoader` 降采样解码。
///
/// 这里不用 NSTextAttachmentViewProvider：TextKit 不保证首次布局后加载视图，视图还会吞掉点击、
/// 遮住选区高亮。附件带一张 1×1 占位图只是为了让 TextKit 走 `image(for:…)` 绘制路径，真图在那里按需提供。
final class CueImageAttachment: NSTextAttachment {
    private static let placeholderSize = CGSize(width: 240, height: 120)
    private static let stub = NSImage(size: NSSize(width: 1, height: 1))

    let imageID: String
    let fileURL: URL?
    weak var owner: CueTextView?
    private lazy var pointSize: CGSize? = fileURL.flatMap(ImageLoading.pointSize(at:))

    init(id: String, fileURL: URL?) {
        imageID = id
        self.fileURL = fileURL
        super.init(data: nil, ofType: nil)
        image = Self.stub
    }

    required init?(coder: NSCoder) { nil }

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
    ) -> NSImage? {
        let owner = owner
        let url = fileURL
        return MainActor.assumeIsolated { owner?.thumbnails.image(at: url, size: bounds.size) }
    }
}
#endif
