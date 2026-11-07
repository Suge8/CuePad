#if os(macOS)
import SwiftUI

/// 舞台只画投影：横向收拢是输入、向外展开是输出；等待只呼吸，不生成音频。
/// Cue 的逐帧微表演与声纹共用状态、采样和动态门禁；角色没有头像底圆。
struct CueVoiceSignal: View {
    let samples: () -> [CGFloat]
    let activity: CueVoicePresentation.Activity
    let muted: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var motion

    // 声纹的最大外扩也留在 320pt 栏的页面边距内，不参与文字与控件排版。
    static let size = CGSize(width: 264, height: 208)
    private static let face: CGFloat = 132

    private var form: CueVoiceRibbon.Form {
        return switch activity {
        case .listening: muted ? .quiet : .inward
        case .speaking: .outward
        case .connecting, .processing: .waiting
        case .failed, .ended: .quiet
        }
    }

    var body: some View {
        let current = motion && form.isAudio ? Array(samples().suffix(CueVoiceRibbon.sampleCount)) : []
        ZStack {
            CueVoiceField(form: form, samples: current,
                          moving: motion, colors: form == .quiet ? [palette.track, palette.track] : [palette.signatureFill, palette.signature, palette.onFill, palette.signature])
            if form == .waiting && motion {
                LoopLayer(kind: .pulse, color: palette.signature)
                    .mask(WaitingEdge().stroke(lineWidth: 1.5))
            }
            CueVoiceCharacter(activity: activity, muted: muted, samples: current)
                .frame(width: Self.face, height: Self.face)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct WaitingEdge: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            Path(CueVoiceRibbon.path(form: .waiting, samples: [], strand: CueVoiceRibbon.strands - 1, in: rect))
        }
    }
}
#endif
