#if os(macOS)
import SwiftUI

/// 通话的微表演复用 Cue 的原始眼神与眨眼帧，不改名牌的常驻节奏。
/// 托腮、抬眼属于思考；讲述手势只由真实输出样本触发，停顿放下，不模拟口型或音素。
/// 音量只控制带滞回的手势选择，不驱动整只缩放、旋转或逐帧重建动画。
struct CueVoiceCharacter: View {
    let activity: CueVoicePresentation.Activity
    let muted: Bool
    let samples: [CGFloat]
    @LoopsPlay private var motion
    @State private var gesturing = false

    private static let gestureOn: CGFloat = 0.16
    private static let gestureOff: CGFloat = 0.04
    private static let smoothingSamples = 6

    private var beat: CueBeat {
        switch activity {
        case .processing: .thinking
        case .failed: .failed
        case .listening: muted ? .resting : .hearing
        case .connecting, .speaking, .ended: .resting
        }
    }

    private var moving: Bool {
        motion && activity.isLive && !(activity == .listening && muted)
    }

    private var level: CGFloat {
        guard moving, activity == .speaking else { return 0 }
        let recent = samples.suffix(Self.smoothingSamples)
        return recent.isEmpty ? 0 : recent.reduce(0, +) / CGFloat(recent.count)
    }

    var body: some View {
        Jelly(value: beat, look: { $0.still }, move: { motion ? JellyMove.cue($0, $1) : nil }) { shown, _ in
            if moving, let sheet = sheet(for: shown) {
                LoopLayer(sprite: Self.sprite(for: shown), sheet: sheet, intro: false)
            } else {
                Image(shown.still).resizable().scaledToFit()
            }
        }
        .task { await CueVoiceGestureAtlas.shared.load() }
        .onChange(of: level, initial: true) { _, level in
            if level < Self.gestureOff { gesturing = false }
            else if level > Self.gestureOn { gesturing = true }
        }
        .accessibilityHidden(true)
    }

    private func sheet(for shown: CueBeat) -> CueAtlas.Sheet? {
        if shown == .resting, activity == .speaking, gesturing {
            return CueVoiceGestureAtlas.shared.sheet ?? CueAtlas.shared.sheet
        }
        return CueAtlas.shared.sheet
    }

    private static let listening = frames("listening", holds: [2.7, 3.9, 2.2], glance: "listening-left")
    private static let thinking = frames("thinking", holds: [0.65, 2.8, 3.6], glance: "thinking-up")

    private static func sprite(for beat: CueBeat) -> CueSprite {
        // hearing 自带整只循环倾斜；通话只用真实的帧动作，保留它的底图而不用那段刚性摆动。
        CueSprite(beat: beat == .hearing ? .resting : beat, intro: [], loop: beat == .thinking ? thinking : listening)
    }

    private static func frames(_ family: String, holds: [Double], glance: String) -> [CueSprite.Frame] {
        func at(_ name: String, _ time: Double) -> CueSprite.Frame { .init(asset: "mascot-cue-\(name)", time: time) }
        return [at(family, holds[0]), at(glance, 0.85), at(family, holds[1]),
                at("\(family)-half", Motion.Beat.halfBlink), at("\(family)-blink", Motion.Beat.blink),
                at("\(family)-half", Motion.Beat.halfBlink), at(family, holds[2])]
    }
}
#endif
