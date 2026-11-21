#if os(iOS)
import SwiftUI

@MainActor final class PreviewSources {
    struct Source {
        let aspect: CGFloat?
        let image: () async -> CGImage?
    }

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

    func taken(_ key: PreviewZoomKey) -> Look? { looks[key] }

    @discardableResult func prepare(_ key: PreviewZoomKey) async -> Look? {
        if let look = looks[key] { return look }
        guard let source = sources[key], let image = await source.image() else { return nil }
        let look = Look(image: image, aspect: source.aspect ?? CGFloat(image.width) / CGFloat(max(image.height, 1)))
        looks[key] = look
        return look
    }
}

struct PreviewLook {
    let sources: PreviewSources
    let key: PreviewZoomKey

    var now: PreviewSources.Look? { sources.taken(key) }
    func load() async -> PreviewSources.Look? { await sources.prepare(key) }
}

extension EnvironmentValues {
    @Entry var previewSources: PreviewSources?
    @Entry var previewLook: PreviewLook?
}
#endif
