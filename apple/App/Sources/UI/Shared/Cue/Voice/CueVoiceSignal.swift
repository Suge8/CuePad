import SwiftUI

/// 同一组声纹始终在场；音轨只在此叶子读取，不让聊天随采样重算。待机、静音、关闭不伪造声音。
struct CueVoiceSignal<Operation: CueVoiceOperation>: View {
    let presentation: CueVoiceState<Operation>?
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
            activity: activity, muted: presentation?.muted == true,
            samples: loopsPlay && presentation?.active == true ? presentation?.samples() ?? [] : [],
            playing: loopsPlay, reduced: reduceMotion)), color: color)
            .frame(width: Self.width, height: Self.height)
            .readerHidden(true)
    }
}
