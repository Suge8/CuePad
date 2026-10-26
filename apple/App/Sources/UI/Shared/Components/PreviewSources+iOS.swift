#if os(iOS)
import SwiftUI

/// 一页上的缩略图各交出自己的画面（`previewSource` 登记，与 Mac 同一个来源）：全屏页在大图解好前先铺它，
/// 系统 zoom 转场第一帧飞的就是有图的页。挂全屏页的那一页一份（`previewPresenter`），只记这一页上出现过的缩略图，随页释放。
/// 画面只在要用时取一次（`prepare`、`look`）；缩略图换了画面（下载到了、换了尺寸）重新登记，取过的作废。
@MainActor final class PreviewSources {
    struct Source {
        /// 内容的真实比例（缩略图裁过时；nil 按画面的）
        let aspect: CGFloat?
        let image: () async -> CGImage?
    }

    /// 取到的画面与它的比例
    struct Look {
        let image: CGImage
        let aspect: CGFloat
    }

    private var sources: [PreviewZoomKey: Source] = [:]
    private var looks: [PreviewZoomKey: Look] = [:]

    func register(_ key: PreviewZoomKey, _ source: Source) {
        sources[key] = source
        looks[key] = nil
    }

    /// 取过的画面，没取过为 nil（不等）。
    func taken(_ key: PreviewZoomKey) -> Look? { looks[key] }

    /// 取这张缩略图的画面并留下；没登记、没有画面为 nil。
    @discardableResult func prepare(_ key: PreviewZoomKey) async -> Look? {
        if let look = looks[key] { return look }
        guard let source = sources[key], let image = await source.image() else { return nil }
        let look = Look(image: image, aspect: source.aspect ?? CGFloat(image.width) / CGFloat(max(image.height, 1)))
        looks[key] = look
        return look
    }
}

/// 全屏页里某一份的缩略图画面（`PreviewSources` 加上这一页是哪一组）：页里先铺它，大图到了再换。
struct PreviewLooks {
    let sources: PreviewSources
    let group: String

    func taken(_ id: UUID) -> PreviewSources.Look? { sources.taken(PreviewZoomKey(group: group, preview: id)) }
    func look(_ id: UUID) async -> PreviewSources.Look? { await sources.prepare(PreviewZoomKey(group: group, preview: id)) }
}

extension EnvironmentValues {
    /// 缩略图登记画面的地方（`previewPresenter` 给，`previewSource` 写）
    @Entry var previewSources: PreviewSources?
    /// 全屏页里取缩略图画面（`PreviewPage` 读）
    @Entry var previewLooks: PreviewLooks?
}
#endif
