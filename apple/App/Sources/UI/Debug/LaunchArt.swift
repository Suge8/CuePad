#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension DebugScene {
    /// 启动图与开门前第一帧同一套摆法（`OpeningDoor.Stage`）、同一张米白字标（`OpeningLight.still`）；系统把图摆在屏幕正中，图就裁成以整组为中心的最小一块。
    static func launchArtIfAsked() {
        guard let folder = args.launchArt else { return }
        let cue = CueOpening.image("cue-stage-idle"), mark = OpeningLight.still(.launch)
        for scale in [2, 3] {
            let s = CGFloat(scale), probe = OpeningDoor.Stage(in: .zero, scale: s, up: 1), box = probe.cue.union(probe.mark)
            let half = CGSize(width: max(-box.minX, box.maxX), height: max(-box.minY, box.maxY))
            let pixels = (width: Int((2 * half.width * s).rounded(.up)), height: Int((2 * half.height * s).rounded(.up)))
            let stage = OpeningDoor.Stage(in: CGRect(x: 0, y: 0, width: CGFloat(pixels.width) / s, height: CGFloat(pixels.height) / s), scale: s, up: 1)
            let context = CGContext(
                data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: s, y: s)
            context.interpolationQuality = .high
            context.draw(cue, in: stage.cue)
            context.interpolationQuality = .none
            context.draw(mark, in: stage.mark)
            let url = URL(fileURLWithPath: folder).appending(path: "launch-stage@\(scale)x.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
#endif
