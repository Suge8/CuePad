import Foundation

/// 头像的帧序列：哪一拍（`CueBeat`）放哪几张、各停多久只在这张表里（`of`），交给渲染服务放（`LoopLayer(sprite:)`，拼图上 `contentsRect` 的离散关键帧）。
/// 帧与各拍的静止图（`CueBeat.still`）都是同一个方画布、脚底同一条基线，帧的黑环与它的底图一像素不动，由 design/tools/cue-frames.py 从同一张底图修补、检查后导出。
/// - 动得稀：会长时间停着的拍子（歇着、在想、等子代理、等你，可能挂几小时）每 15～20s 才动一下，间隔不规则，不像节拍器。
///   一下是一次眨眼或一次张望（只往一边看再回来）；不双眨。每一下都要渲染服务合成几帧，次数就是静置开销（docs/perf.md）。
/// - 做完只在换进来的那一下欢呼一次（`intro`，放不放由 `LoopLayer.intro` 定：层重建不重放），之后静止举着、同样稀疏地眨眼；起不来、不在不动。在听只有几秒，照常眨眼。
/// - 眨眼是睁 → 半闭 → 闭 → 半闭 → 睁，约 0.15s：只有睁、闭两张时在名片上像闪了一下。
/// - 小尺寸（`compact`，32pt 及以下）只留轮廓变了的帧（凉棚、欢呼）：眼睛只挪一两点，看不出来，换帧却照样要渲染服务合成。
struct CueSprite: Hashable {
    let beat: CueBeat
    /// 进来时放一遍，之后接 `loop`。
    let intro: [Frame]
    /// 一圈从头再来；不到两帧时静止。
    let loop: [Frame]

    struct Frame: Hashable {
        let asset: String
        let time: Double
    }

    /// 整只连续地倾（往耳朵那边倾、回正，`Motion.Beat.leanPeriod`）：渲染服务要逐帧合成，不能当作只换帧的开销。
    /// 只给几秒就过去的在听；由拍子决定、不是可填的字段——给别的拍子加连续动作要改这里，并重新量。
    var leans: Bool { beat == .hearing }

    private struct Key: Hashable {
        let beat: CueBeat
        let compact: Bool
    }
    private static var cache: [Key: CueSprite] = [:]

    static func of(_ beat: CueBeat, compact: Bool) -> CueSprite {
        let key = Key(beat: beat, compact: compact)
        if let sprite = cache[key] { return sprite }
        let sprite = make(beat, compact: compact)
        cache[key] = sprite
        return sprite
    }

    private static func make(_ beat: CueBeat, compact: Bool) -> CueSprite {
        let base = beat.still
        func at(_ name: String?, _ time: Double, outline: Bool = false) -> [Frame] {
            // 只动眼睛的帧在小尺寸里画底图
            let asset = name.map { compact && !outline ? base : "mascot-cue-\($0)" } ?? base
            return [Frame(asset: asset, time: time)]
        }
        func blink(_ family: String) -> [Frame] {
            at("\(family)-half", Motion.Beat.halfBlink) + at("\(family)-blink", Motion.Beat.blink) + at("\(family)-half", Motion.Beat.halfBlink)
        }
        let loop: [Frame]
        var intro: [Frame] = []
        switch beat {
        case .resting:
            loop = at(nil, 16.4) + blink("listening") + at(nil, 18.3) + at("listening-left", 0.9) + at(nil, 15.6) + blink("listening")
        case .hearing:
            loop = at(nil, 4.9) + blink("listening") + at(nil, 3.8) + blink("listening") + at(nil, 1.2)
        case .thinking:
            // 托腮：往上想一下的长短不等
            loop = at(nil, 17.2) + at("thinking-up", 1.2) + at(nil, 15.8) + blink("thinking") + at(nil, 19.1) + at("thinking-up", 1.6)
        case .delegating:
            // 手搭凉棚：右望长停，偶尔往左瞟一眼
            loop = at(nil, 15.9) + blink("visor") + at(nil, 18.6) + at("visor-left", 0.9) + at(nil, 16.8) + blink("visor")
        case .waiting:
            loop = at(nil, 18.1) + blink("waiting") + at(nil, 15.7) + blink("waiting") + at(nil, 17.4) + blink("waiting")
        case .done:
            intro = at("done-2", 0.4, outline: true) + at(nil, 0.4) + at("done-2", 0.4, outline: true)
            loop = at(nil, 16.8) + blink("done") + at(nil, 19.3) + blink("done")
        case .failed, .away:
            loop = []
        }
        // 小尺寸里只剩底图的圈就是静止
        let still = Set(loop.map(\.asset)).count < 2
        return CueSprite(beat: beat, intro: intro, loop: still ? [] : loop)
    }
}

extension Motion {
    /// 头像与状态标的节奏（帧序列各停多久在 `CueSprite.of`，两颗点的关键时刻在 `RelayMark`）。
    /// 常驻的连续摆动避开 5 秒上下（0.2Hz 的持续摆动最招晕），在 3～4 秒。
    nonisolated enum Beat {
        /// 眨眼：闭眼那一张停多久，前后半闭各停多久。
        static let blink = 0.07
        static let halfBlink = 0.04
        /// 在听时身体往耳朵那边倾的角度（度）与一个来回。
        static let lean = 2.5
        static let leanPeriod = 3.4
        /// 连续的循环（心电线、两颗点、在听的倾）最高多少帧每秒：这么小的图形用不着 120Hz。
        static let frameRate: Float = 30
    }
}
