import SwiftUI

struct CueVoiceSignal: View {
    let presentation: CueVoicePresentation?
    var seed = false
    @Environment(\.palette) private var palette
    @LoopsPlay private var loopsPlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var width: CGFloat { 52 }
    private static var height: CGFloat { 28 }

    var body: some View {
        let activity = presentation?.activity
        let resting = activity == nil || activity == .idle || activity == .ended || (presentation?.muted == true && activity != .speaking)
        let color = activity == .failed ? palette.failure : resting ? palette.ink3 : palette.signature
        LoopLayer(kind: .voice(VoiceRibbon(
            activity: activity, muted: presentation?.muted == true, seed: seed,
            samples: loopsPlay && presentation?.active == true ? presentation?.samples() ?? [] : [],
            playing: loopsPlay, reduced: reduceMotion)), color: color)
            .frame(width: Self.width, height: Self.height)
            .readerHidden(true)
    }
}
