#if os(macOS)
import SwiftUI

/// 真实声音的短历史，不用时间轴或随机数补出声音。不可见、减弱动态和省电时收成静线；状态文字仍保留。
struct CueVoiceSignal: View {
    let samples: [CGFloat]
    let active: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var motion

    // 只取最近 32 个采样柱，宽度与高度不随声音改变，避免把音频更新传进外层排版。
    nonisolated private static let count = 32
    static let width: CGFloat = 176
    static let height: CGFloat = 32

    var body: some View {
        Signal(samples: active && motion ? Array(samples.suffix(Self.count)) : [])
            .stroke(active ? palette.signature : palette.ink3, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: Self.width, height: Self.height)
            .transaction { $0.animation = nil }
            .readerHidden(true)
    }

    nonisolated private struct Signal: Shape {
        let samples: [CGFloat]

        func path(in rect: CGRect) -> Path {
            Path { path in
                let step = rect.width / CGFloat(CueVoiceSignal.count)
                for index in 0..<CueVoiceSignal.count {
                    let offset = index - (CueVoiceSignal.count - samples.count)
                    let level = offset >= 0 ? min(1, max(0, samples[offset])) : 0
                    let half = max(0.5, level * (rect.height / 2 - 2))
                    let x = (CGFloat(index) + 0.5) * step
                    path.move(to: CGPoint(x: x, y: rect.midY - half))
                    path.addLine(to: CGPoint(x: x, y: rect.midY + half))
                }
            }
        }
    }
}
#endif
