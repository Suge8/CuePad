#if os(macOS)
import SwiftUI

/// 通话专用的六块局部纹理：身体、双眼、双手与担忧眉形。身体不换片，手腕和视线由呈现层连续衔接。
/// 一张 1450×240 PNG，首次进入通话后台解码一次；BGRA 原始像素约 1.33MiB，不含系统缓存与渲染表面。
@Observable final class CueVoiceGestureAtlas {
    static let shared = CueVoiceGestureAtlas()
    private(set) var image: CGImage?
    @ObservationIgnored private var loading = false

    func load() async {
        guard !loading else { return }
        loading = true
        image = await Self.decode(in: NSScreen.main?.colorSpace?.cgColorSpace)
    }

    @concurrent private static func decode(in space: CGColorSpace?) async -> CGImage? {
        guard let source = NSImage(named: "mascot-cue-voice-parts")?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space ?? source.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }
}
#endif
