import CueStore
import SwiftUI

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
        let line = max(1.4, size * 0.095)
        return ZStack {
            if status == .inProgress, running {
                if sweeps { LoopLayer(kind: .orbit, color: palette.signature) } else { Circle().stroke(palette.signature, lineWidth: line) }
            } else if status == .inProgress {
                Circle().stroke(palette.ink, lineWidth: line)
                HalfDisc().fill(palette.ink).padding(line * 1.6)
            } else {
                Circle().stroke(palette.ink3, lineWidth: line)
            }
        }
        .animation(Motion.fade, value: status)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }

    private func segments(_ steps: TaskProgress) -> some View {
        let line = max(1.4, size * 0.095), count = steps.total
        let gap = min(0.04, 0.25 / Double(count))
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

nonisolated private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.closeSubpath()
        }
    }
}
