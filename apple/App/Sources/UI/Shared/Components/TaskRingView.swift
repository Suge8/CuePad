import CueStore
import SwiftUI

/// 任务的完成圈（`TaskRing`），全 App 的任务只有这一种图形（行、任务页、书架"正在推进"、挂到任务面板、Mac 面板）：
/// 完成是对勾；没完成的是一个实线圈，进行中左半填满，待办空心——这个形状只随状态变，有没有下级、下级做了多少都不换掉它。
/// 有下级、还没全做完时进度不画进圈里，在圈下面一条细的横条（`TaskProgressBar`）：做完的下级占多少填多少，空槽看得见；
/// 全做完不画（`TaskRing`）。圈里不画扇形或楔形：小比例时一根细楔像表盘指针、读成在计时；也不在圈外描弧：小尺寸下那就是
/// 系统的加载转圈。条只在 `TaskProgressBar.shows(ringSize:)` 时画（Mac 不画、iPhone 上小圈不画），进度看元信息那一行。
/// 进度条叠在圈下（落在行的第二行左边、元信息那一行旁边），不占行高；条是次要墨色，不与圈连成一道下划线。
struct TaskRingView: View {
    let status: TaskStatus?
    let ring: TaskRing
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
                    .transition(.opacity)
            } else {
                open
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        .overlay(alignment: .bottom) {
            if !finished, TaskProgressBar.shows(ringSize: size), case .progress(let done, let total) = ring {
                TaskProgressBar(done: done, total: total)
                    .frame(width: size * 0.88)
                    .offset(y: size * 0.24 + TaskProgressBar.height)
                    .transition(.opacity)
            }
        }
        .animation(Motion.spatial(Motion.quick, reduceMotion: reduceMotion), value: ring)
        .animation(Motion.quick, value: done)
        .accessibilityHidden(true)
    }

    /// 与 SF 的 circle 同尺寸同线宽的实线圈（颜色照状态）；进行中左半填满，与圈线留一线缝。
    private var open: some View {
        let tint = TaskGlyph.tint(status, palette), line = max(1.4, size * 0.095)
        return ZStack {
            Circle().stroke(tint, lineWidth: line)
            if status == .inProgress { Circle().trim(from: 0.25, to: 0.75).fill(tint).padding(line * 1.1) }
        }
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }
}


/// 任务圈下的进度：一条 2pt 的细横条，做完的下级占的比例用次要墨色填实，空槽是看得见的淡墨。不分格：圈只有十几点宽，
/// 分成几格就成了一串省略号。
struct TaskProgressBar: View {
    let done: Int
    let total: Int
    @Environment(\.palette) private var palette

    static let height: CGFloat = 2
    /// 圈下画不画条。Mac 上不画：Mac 的圈最大 20 点，条只有十来点宽，像圈下一小块污点；进度在旁边那行"子任务 1/2"里已经写着。
    /// iPhone 上圈小于 16 点时同理不画。
    static func shows(ringSize: CGFloat) -> Bool {
        #if os(macOS)
        false
        #else
        ringSize >= 16
        #endif
    }

    var body: some View {
        Capsule().fill(palette.ink3.opacity(0.4))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(palette.ink2).frame(width: proxy.size.width * Double(done) / Double(max(total, 1)))
                }
            }
            .frame(height: Self.height)
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
