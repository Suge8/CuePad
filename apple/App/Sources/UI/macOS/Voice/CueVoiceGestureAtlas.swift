#if os(macOS)
import SwiftUI

/// 仅通话使用的一张 604×200 手势纹理：原图局部改手，其余像素与 listening 完全相同。
/// 三格是讲述、半闭、闭眼，沿用共享播放器的帧名；不复制共享图集，不增加运行时。
/// 首次进入通话在后台解码一次，BGRA 像素约 472KiB；未就绪时继续画同位置的原姿态。
@Observable final class CueVoiceGestureAtlas {
    static let shared = CueVoiceGestureAtlas()
    private(set) var sheet: CueAtlas.Sheet?
    @ObservationIgnored private var loading = false

    func load() async {
        guard !loading else { return }
        loading = true
        sheet = await Self.decode(in: NSScreen.main?.colorSpace?.cgColorSpace)
    }

    @concurrent private static func decode(in space: CGColorSpace?) async -> CueAtlas.Sheet? {
        guard let source = NSImage(named: "mascot-cue-voice-speaking")?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space ?? source.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let image = context.makeImage() else { return nil }
        let stride: CGFloat = 202, side: CGFloat = 200, width = CGFloat(image.width)
        let rects = Dictionary(uniqueKeysWithValues: ["listening", "listening-half", "listening-blink", "listening-left"].enumerated().map { index, name in
            ("mascot-cue-\(name)", CGRect(x: index == 3 ? 0 : CGFloat(index) * stride / width, y: 0, width: side / width, height: 1))
        })
        return CueAtlas.Sheet(image: image, rects: rects)
    }
}
#endif
