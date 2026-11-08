import SwiftUI

/// 只在声音叶子订阅真实采样；无样本就是静线，不用时钟伪造讲话。
struct CueVoiceSignal: View {
    let samples: () -> [CGFloat]
    @Environment(\.palette) private var palette
    private static let width: CGFloat = 28
    private static let height: CGFloat = 16

    var body: some View {
        Wave(samples: samples()).stroke(palette.signature, lineWidth: 1.5)
            .frame(width: Self.width, height: Self.height)
            .readerHidden(true)
    }

    private struct Wave: Shape {
        let samples: [CGFloat]
        nonisolated func path(in rect: CGRect) -> Path {
            let values = samples.isEmpty ? [CGFloat.zero, 0] : samples
            return Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: rect.width * CGFloat(index) / CGFloat(max(1, values.count - 1)),
                                        y: rect.midY + (index.isMultiple(of: 2) ? -1 : 1) * value * rect.height / 2)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }
    }
}
