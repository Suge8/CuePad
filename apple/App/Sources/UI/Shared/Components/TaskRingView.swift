import CueStore
import SwiftUI

/// 任务的完成圈，全 App 的任务只有这一种图形（行、步骤、任务页、书架"正在推进"、Mac 面板）：完成是对勾；没完成的是一个实线圈，
/// 进行中左半填满，待办空心——形状只随状态变。步骤做了多少不画进圈里（圈里的扇形小比例时像表盘指针，圈外描弧小尺寸下就是系统的
/// 加载转圈，圈下挂进度条像一小块污点），写在行尾的"n/m"里（`TaskLine`）。
struct TaskRingView: View {
    let status: TaskStatus?
    /// 界面上已经显示完成（勾了还没写入时也算）。
    let done: Bool
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var finished: Bool { done || status == .done }

    var body: some View {
        Group {
            if finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(TaskGlyph.tint(.done, palette))
                    // 对勾从圈里长出来：缩放加淡入，无回弹（ui.md 动效）；减弱动态效果时直接换上
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                open
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: finished)
        .accessibilityHidden(true)
    }

    /// 与 SF 的 circle 同尺寸同线宽的实线圈（颜色照状态）；进行中左半填满，与圈线留一线缝。
    private var open: some View {
        let tint = TaskGlyph.tint(status, palette), line = max(1.4, size * 0.095)
        return ZStack {
            Circle().stroke(tint, lineWidth: line)
            if status == .inProgress { Circle().trim(from: 0.25, to: 0.75).fill(tint).padding(line * 1.1).transition(.opacity) }
        }
        .animation(Motion.quick, value: status)
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }
}

/// 任务圆圈的颜色（形状只在 `TaskRingView`）：待办淡墨、进行中与完成墨色。
/// 进行中不用签名色：在动的状态靠形状区分，签名色只给一屏的焦点。
enum TaskGlyph {
    static func tint(_ status: TaskStatus?, _ palette: Palette) -> Color {
        switch status {
        case .done, .inProgress: palette.ink
        case .todo, nil: palette.ink3
        }
    }
}
