import CueStore
import OSLog
import QuartzCore
import SwiftUI
import Synchronization

/// 头像的全部图（各拍静止图与 `CueSprite` 里出现的每一帧）拼成一张横条：帧序列换帧只改 `contentsRect`，渲染服务里始终是这一张纹理。
/// 启动时在后台解一次（`load`），主线程不解 PNG；万一解好之前头像就要画，画 SwiftUI 的静止图（`CueAvatar`），两者同一张图、同一个框，换过去看不出。
/// 每格 200px 方画布原样摆、格间留空隙（缩小取样不把邻格的边带进来），脚底基线与画布不变；二十来张，约 3.5MB。
@Observable final class CueAtlas {
    static let shared = CueAtlas()

    struct Sheet: Equatable, @unchecked Sendable {
        let image: CGImage
        /// 每张图在横条里的单位矩形（`contentsRect`）。
        let rects: [String: CGRect]

        /// 一个进程只拼一张：同一张图就是同一份。
        static func == (lhs: Sheet, rhs: Sheet) -> Bool { lhs.image === rhs.image }
    }

    /// 解好之前为 nil。后台解好就写进 `built`，读的那一刻直接拿到，不等主线程的回合交过来（首屏那一帧常常就在这几十毫秒里）；
    /// 解好时另通知读过它的视图（先画了静止图的那几只换成拼图）。
    var sheet: Sheet? {
        access(keyPath: \.sheet)
        return Self.built.withLock { $0 }
    }

    nonisolated private static let built = Mutex<Sheet?>(nil)
    @ObservationIgnored private var loading = false

    private init() {}

    /// 启动时调一次，在后台解码、拼好（十几毫秒）：不等首帧——首屏就有头像，等首帧再解的话头像第一次出现画的是静止图，由系统在主线程解。
    func load() {
        guard !loading else { return }
        loading = true
        let names = Array(Set(CueBeat.allCases.flatMap { beat in
            [beat.still] + [false, true].flatMap { compact in
                let sprite = CueSprite.of(beat, compact: compact)
                return (sprite.intro + sprite.loop).map(\.asset)
            }
        })).sorted()
        let target = Self.displaySpace()
        Task.detached(priority: .userInitiated) {
            let sheet = Self.build(names, into: target)
            Self.built.withLock { $0 = sheet }
            await MainActor.run { CueAtlas.shared.withMutation(keyPath: \.sheet) {} }
        }
    }

    nonisolated private static let gap = 2
    /// 解码在哪条线程、花多久（验证主线程不解：`log show --predicate 'category == "cue-atlas"'`）。
    nonisolated private static let log = Logger(subsystem: AppIdentity.id, category: "cue-atlas")

    nonisolated private static func build(_ names: [String], into target: CGColorSpace?) -> Sheet? {
        let start = ContinuousClock.now
        let images = names.compactMap { name in source(name).map { (name, $0) } }
        guard images.count == names.count, let first = images.first?.1 else {
            let missing = Set(names).subtracting(images.map(\.0)).sorted().joined(separator: "、")
            log.error("拼图缺帧，头像只画静止图：\(missing, privacy: .public)")
            return nil
        }
        defer {
            let space = describe(first.colorSpace)
            let into = target.map(describe) ?? "同源图"
            log.notice("拼图解好：\(names.count, privacy: .public) 张，\(ContinuousClock.now - start, privacy: .public)，主线程 \(Thread.isMainThread, privacy: .public)，\(space, privacy: .public) → \(into, privacy: .public)")
        }
        let side = first.width, height = first.height, stride = side + gap
        guard let context = CGContext(
            data: nil, width: stride * images.count - gap, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: target ?? space(of: first),
            // BGRA 预乘是 Core Animation 直接收的格式：给 RGBA 的话交上去那一下主线程要整张转一遍
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var rects: [String: CGRect] = [:]
        let total = CGFloat(context.width)
        for (index, (name, image)) in images.enumerated() {
            context.draw(image, in: CGRect(x: index * stride, y: 0, width: side, height: height))
            rects[name] = CGRect(x: CGFloat(index * stride) / total, y: 0, width: CGFloat(side) / total, height: 1)
        }
        return context.makeImage().map { Sheet(image: $0, rects: rects) }
    }

    nonisolated private static func source(_ name: String) -> CGImage? {
        #if os(iOS)
        UIImage(named: name)?.cgImage
        #else
        NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// 拼图画进哪个色彩空间。Mac 是启动时主屏的空间（常是显示器自己的无名 ICC 配置）：Core Animation 按屏幕空间合成，拼图不是同一个空间对象时，
    /// 建层交上去那一下要在主线程整张转一遍（Time Profiler 里 `CA::Render::copy_image`），所以在后台按色彩管理先转好，看起来与静止图一样。
    /// 只取这一次、不随窗口换屏重建：换到别的屏颜色照样对（Core Animation 自己转），只是之后建层的那一下回到主线程转一次（4240×200，约 3ms），
    /// 换屏少见，为它监听屏幕变化、重拼、换掉在用的图层不值。iOS 为 nil，沿用源图的 sRGB（未量过 iOS 上交上去时转不转）。
    private static func displaySpace() -> CGColorSpace? {
        #if os(macOS)
        NSScreen.main?.colorSpace?.cgColorSpace
        #else
        nil
        #endif
    }

    /// 日志里的空间名：显示器的 ICC 配置没有名字，写成"无名 ICC（字节数）"，不回落到源图的名字。
    nonisolated private static func describe(_ space: CGColorSpace?) -> String {
        guard let space else { return "无" }
        if let name = space.name { return name as String }
        return "无名 ICC（\(space.copyICCData().map { CFDataGetLength($0) } ?? 0) 字节）"
    }

    /// 没有屏幕空间时画进源图自己的色彩空间：一律画进设备 RGB 的话，P3 屏上帧序列与静止图（`Image(still)`）有色差，循环一开一关就看得出。
    nonisolated private static func space(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
