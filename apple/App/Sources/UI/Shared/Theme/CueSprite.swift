import Foundation

struct CueSprite: Hashable {
    let beat: CueBeat
    let intro: [Frame]
    let loop: [Frame]

    struct Frame: Hashable {
        let asset: String
        let time: Double
    }

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
            loop = at(nil, 17.2) + at("thinking-up", 1.2) + at(nil, 15.8) + blink("thinking") + at(nil, 19.1) + at("thinking-up", 1.6)
        case .delegating:
            loop = at(nil, 15.9) + blink("visor") + at(nil, 18.6) + at("visor-left", 0.9) + at(nil, 16.8) + blink("visor")
        case .waiting:
            loop = at(nil, 18.1) + blink("waiting") + at(nil, 15.7) + blink("waiting") + at(nil, 17.4) + blink("waiting")
        case .done:
            intro = at("done-2", 0.4, outline: true) + at(nil, 0.4) + at("done-2", 0.4, outline: true)
            loop = at(nil, 16.8) + blink("done") + at(nil, 19.3) + blink("done")
        case .failed, .away:
            loop = []
        }
        let still = Set(loop.map(\.asset)).count < 2
        return CueSprite(beat: beat, intro: intro, loop: still ? [] : loop)
    }
}

extension Motion {
    nonisolated enum Beat {
        static let blink = 0.07
        static let halfBlink = 0.04
        static let lean = 2.5
        static let leanPeriod = 3.4
        static let frameRate: Float = 30
    }
}
