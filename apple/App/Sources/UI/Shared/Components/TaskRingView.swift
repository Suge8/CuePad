import CueStore
import SwiftUI

/// 任务的完成圈，全 App 的任务只有这一种图形（行、步骤、任务页、Cue 页的任务行、Mac 面板）：完成是石绿的对勾；没完成的是一个实线圈，
/// 进行中左半填满，待办空心。有两步以上步骤的（`steps`），圈按步骤分段：做完的段是墨色实线，没做完的是轨道色，
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
        Jelly(value: finished, move: { old, new in !old && new ? .pop : nil }) { finished, leaving in
            if finished || leaving {
                Image(leaving ? .donePending : .done)
                    .font(.system(size: size))
                    .foregroundStyle(TaskGlyph.tint(.done, palette))
            } else if let steps, steps.total >= 2 {
                segments(steps)
            } else {
                open
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        .accessibilityHidden(true)
    }

    /// 与 SF 的 circle 同尺寸同线宽的实线圈（颜色照状态）；进行中左半填满，与圈线留一线缝。
    private var open: some View {
        let tint = TaskGlyph.tint(status, palette), line = max(1.4, size * 0.095)
        return ZStack {
            Circle().stroke(tint, lineWidth: line)
            if status == .inProgress { Circle().trim(from: 0.25, to: 0.75).fill(tint).padding(line * 1.1).transition(.opacity) }
        }
        .animation(HandOff.quick, value: status)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }

    /// 分段的圈：从十二点起顺时针，一步一段，段间留一点缝（步数多时缝跟着收窄，段不被缝吃掉）。
    private func segments(_ steps: TaskProgress) -> some View {
        let line = max(1.6, size * 0.11), count = steps.total
        let gap = min(0.05, 0.3 / Double(count))
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let arc = Circle().trim(from: Double(index) / Double(count) + gap / 2, to: Double(index + 1) / Double(count) - gap / 2)
                    .stroke(style: StrokeStyle(lineWidth: line))
                if index == steps.done, running {
                    arc.foregroundStyle(sweeps ? palette.selection : palette.signature)
                        .overlay { if sweeps { LoopLayer(kind: .sheen, color: palette.signature).mask { arc } } }
                } else {
                    arc.foregroundStyle(index < steps.done ? palette.ink : palette.track)
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .animation(HandOff.quick, value: steps.done)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }
}

/// 任务圆圈的颜色（形状只在 `TaskRingView`）：待办淡墨、进行中墨色、完成是石绿的对勾（石绿的两种用途见 `Palette`）。
/// 进行中不用签名色：在动的状态靠形状区分，签名色只给一屏的焦点。
enum TaskGlyph {
    static func tint(_ status: TaskStatus?, _ palette: Palette) -> Color {
        switch status {
        case .done: palette.replied
        case .inProgress: palette.ink
        case .todo, nil: palette.ink3
        }
    }
}
