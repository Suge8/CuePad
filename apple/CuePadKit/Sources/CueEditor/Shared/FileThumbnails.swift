import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// 文件牌的缩略图：系统快速查看的缩略图（出不了画面的给类型图标），后台出好、按文件记着，出好了请求重画这个文件的牌子。
/// 只在牌子被绘制（进入视口）时才要，视口外的文件不读。
@MainActor
final class FileThumbnails {
    private unowned let core: EditorCore
    private var made: [URL: CGImage] = [:]
    private var tried = Set<URL>()

    init(core: EditorCore) { self.core = core }

    /// 出好的那张；还没出（或出不了）为 nil，此时开始出。
    func image(at url: URL, key: String) -> CGImage? {
        if let image = made[url] { return image }
        guard tried.insert(url).inserted else { return nil }
        let side = FileChip.thumbSide, scale = core.displayScale
        Task { [weak self] in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all)
            guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage, let self else { return }
            made[url] = image
            core.redrawFiles(key)
        }
        return nil
    }
}
