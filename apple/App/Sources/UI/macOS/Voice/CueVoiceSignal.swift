#if os(macOS)
import SwiftUI

/// 舞台只画投影：横向收拢是输入、向外展开是输出；等待只呼吸，不生成音频。
/// Cue 用完整品牌原图悬在声纹中，避免头像底圆把它读成通讯录联系人。
struct CueVoiceSignal: View {
    let samples: () -> [CGFloat]
    let activity: CueVoicePresentation.Activity
    let muted: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var motion

    // 声纹的最大外扩也留在 320pt 栏的页面边距内，不参与文字与控件排版。
    static let size = CGSize(width: 264, height: 208)
    private static let face: CGFloat = 88

    private var form: CueVoiceRibbon.Form {
        return switch activity {
        case .listening: muted ? .quiet : .inward
        case .speaking: .outward
        case .connecting, .processing: .waiting
        case .failed, .ended: .quiet
        }
    }

    private var beat: CueBeat {
        switch activity {
        case .connecting, .processing: .thinking
        case .failed: .failed
        case .ended: .away
        case .listening, .speaking: .hearing
        }
    }

    var body: some View {
        ZStack {
            CueVoiceField(form: form, samples: motion && form.isAudio ? Array(samples().suffix(CueVoiceRibbon.sampleCount)) : [],
                          moving: motion && form != .quiet, colors: form == .quiet ? [palette.track, palette.track] : [palette.signatureFill, palette.signature, palette.onFill, palette.signature])
            if form == .waiting && motion {
                LoopLayer(kind: .pulse, color: palette.signature)
                    .mask(WaitingEdge().stroke(lineWidth: 1.5))
            }
            Image(beat.still).resizable().scaledToFit()
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
