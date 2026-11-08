import CueStore
import SwiftUI

/// 任务的完成圈，全 App 的任务只有这一种图形（行、子任务、进展页、Cue 页的任务行、Mac 面板）：完成是石绿的对勾；待办空心，
/// 进行中是静止开口弧，只表示状态、不表示百分比。有两步以上子任务的（`steps`），圈按子任务分段：做完的段是墨色实线，没做完的是轨道色，
/// 此刻那一步的会话在跑时（`running`）那一段是靛青浅底上走一道流光（`LoopLayer` 的 sheen，进行中文字上扫过的那道光）；进度只画在圈上，行尾不写"n/m"。
/// 勾上的那一下：圈按下去成一颗点（`Icon.donePending`），压到最扁时点弹成勾（`Jelly` 的 pop）；减弱动态效果时只淡入淡出；不放循环动效时（`LoopsPlay`）流光换成静止的靛青。
struct TaskRingView: View {
    let status: TaskStatus?
    /// 界面上已经显示完成（勾了还没写入时也算）。
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

    /// 待办完整空圈，进行中保留圆头开口；不叠内圈或填充，也不循环旋转。
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

    /// 分段的圈：从十二点起顺时针，一步一段，段间留一点缝（步数多时缝跟着收窄，段不被缝吃掉）。
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
