#if os(macOS)
import SwiftUI

/// 通话角色由纸片身体、双眼和双手组成；手腕与视线独立衔接，不以整图换片或摆动替代表演。
/// 样本只选择讲述的强调与停顿，不能代表音素；循环与转场共用页面、减弱动态和省电门禁。
struct CueVoiceCharacter: View {
    let activity: CueVoicePresentation.Activity
    let muted: Bool
    let samples: [CGFloat]
    @LoopsPlay private var motion
    @State private var gesturing = false

    private static let gestureOn: CGFloat = 0.16
    private static let gestureOff: CGFloat = 0.04
    private static let smoothingSamples = 6

    private var moving: Bool { motion && activity.isLive && !(activity == .listening && muted) }

    private var level: CGFloat {
        guard moving, activity == .speaking else { return 0 }
        let recent = samples.suffix(Self.smoothingSamples)
        return recent.isEmpty ? 0 : recent.reduce(0, +) / CGFloat(recent.count)
    }

    var body: some View {
        Group {
            if let image = CueVoiceGestureAtlas.shared.image {
                CueVoicePuppet(image: image, pose: .init(activity: activity, muted: muted, emphasis: gesturing), animate: motion, blinking: moving)
            } else {
                Image(decorative: "mascot-cue-listening").resizable().scaledToFit().padding(Spacing.inset)
            }
        }
        .task { await CueVoiceGestureAtlas.shared.load() }
        .onChange(of: level, initial: true) { _, level in
            if level < Self.gestureOff { gesturing = false }
            else if level > Self.gestureOn { gesturing = true }
        }
        .accessibilityHidden(true)
    }
}
#endif
