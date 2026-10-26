import QuartzCore
import SwiftUI

/// 话在路上那架纸飞机（`LoopLayer.Kind.flight`）的一趟与剪影。
extension LoopLayer.Host {
    /// 纸飞机的一趟：飞进来（缓出）、在正中停一下、飞出去（缓入），飞的方向顺着机头（右上），距离是框边的六成。
    enum Flight {
        static let period = 1.3
        static let keyTimes: [NSNumber] = [0, 0.32, 0.62, 1]
    }

    /// 飞的那一趟的位移与透明度（位移是相对正中的变换：不播时就停在正中）。层 y 朝下（两端同，`LoopLayer.Host`），右上是 -y。
    static func flightPath(side: CGFloat) -> [CAAnimation] {
        let distance = side * 0.6
        let up = -distance
        let across = CAKeyframeAnimation(keyPath: "transform.translation.x")
        across.values = [-distance, 0, 0, distance]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [-up, 0, 0, up]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        for animation in [across, rise, fade] {
            animation.keyTimes = Flight.keyTimes
            animation.timingFunctions = [.init(name: .easeOut), .init(name: .linear), .init(name: .easeIn)]
        }
        return [across, rise, fade]
    }

    /// 纸飞机的剪影（只用来做遮罩，颜色由层底色给），按边长与屏幕倍数缓存。用平台的符号图直接画，不起一份 SwiftUI 渲染（发出那一刻就要它）。
    private static var planes: [PlaneKey: CGImage] = [:]

    private struct PlaneKey: Hashable {
        let side: CGFloat
        let scale: CGFloat
    }

    static func plane(side: CGFloat, scale: CGFloat) -> CGImage? {
        let key = PlaneKey(side: side, scale: scale)
        if let cached = planes[key] { return cached }
        let pixels = Int((side * scale).rounded())
        guard let symbol = Icon.send.platformImage, pixels > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let point = side * 0.86
        #if os(iOS)
        guard let sized = symbol.applyingSymbolConfiguration(.init(pointSize: point, weight: .semibold)) else { return nil }
        UIGraphicsPushContext(context)
        // CGContext 的 y 朝上，UIKit 画图按 y 朝下
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        sized.draw(in: CGRect(x: (side - sized.size.width) / 2, y: (side - sized.size.height) / 2, width: sized.size.width, height: sized.size.height))
        UIGraphicsPopContext()
        #else
        guard let sized = symbol.withSymbolConfiguration(.init(pointSize: point, weight: .semibold)) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        sized.draw(in: NSRect(x: (side - sized.size.width) / 2, y: (side - sized.size.height) / 2, width: sized.size.width, height: sized.size.height))
        NSGraphicsContext.restoreGraphicsState()
        #endif
        planes[key] = context.makeImage()
        return planes[key]
    }
}
