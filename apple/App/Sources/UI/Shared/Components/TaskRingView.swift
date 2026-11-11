import CueStore
import SwiftUI

/// 进度只画在圈上，行尾不写"n/m"。
struct TaskRingView: View {
    let status: TaskStatus?
    let done: Bool
    let size: CGFloat
    var steps: TaskProgress?
    var running = false
    @Environment(\.palette) private var palette
    @LoopsPlay private var sweeps

    private var finished: Bool { done || status == .done }

    var body: some View {
        Jelly(value: finished, look: { $0 }, move: { old, new in !old && new ? .pop : nil }) { finished, phase in
            if finished || phase == .leaving {
                Image(phase == .leaving ? .donePending : .done)
                    .font(.system(size: size))
                    .foregroundStyle(palette.replied)
            } else if let steps, steps.total >= 2 {
                segments(steps)
            } else { open }
        }
        .readerHidden(true)
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
    }

    private var open: some View {
        let tint = status == .inProgress ? palette.ink : palette.ink3, line = max(1.4, size * 0.095)
        return ZStack {
            if status == .inProgress {
                Circle().trim(from: 0.08, to: 0.86)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else { Circle().stroke(tint, lineWidth: line) }
        }
        .animation(Motion.fade, value: status)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }

    private func segments(_ steps: TaskProgress) -> some View {
        let line = max(1.4, size * 0.095), count = steps.total
        let gap = min(0.04, 0.25 / Double(count))
        // 圆帽会向缝里各伸半个线宽；小尺寸或密集分段改用平端，不能把步骤粘成整圈。
        let rounded = CGFloat(gap) * .pi * size * 0.88 > line * 1.2
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let arc = Circle().trim(from: Double(index) / Double(count) + gap / 2, to: Double(index + 1) / Double(count) - gap / 2)
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: rounded ? .round : .butt))
                if index == steps.done, running {
                    arc.foregroundStyle(sweeps ? palette.selection : palette.signature)
                        .overlay { if sweeps { LoopLayer(kind: .sheen, color: palette.signature).mask { arc } } }
                } else {
                    arc.foregroundStyle(index < steps.done ? palette.ink : palette.track)
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .animation(Motion.fade, value: steps.done)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }
}
