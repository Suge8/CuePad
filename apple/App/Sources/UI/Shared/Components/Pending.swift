import SwiftUI

/// 数据还没到、本机不确定是不是最新时的样子，全 App 一份：各页只说"还没读到"（`loading`）、"这一页在等同步"（`SyncingLabel`、
/// `EmptyState` 的 `waitsForSync`），怎么出现只在这里定。"同步中"只有一个来源（`AppServices.isCatchingUp`）。
/// 读本机库一般几十毫秒、回到前台的那一拉多在一秒以内：这期间什么都不出，免得一闪；过了 `delay` 还没好才淡入
/// （`Spinner`，减弱动态效果时是静止的一段弧），好了就撤下。内容到了直接排在终位，不做入场动画。
enum Pending {
    /// 比这快的读与拉不出指示：一闪而过的转圈比稍等一下更扰人。
    static let delay = Duration.milliseconds(400)
}

extension View {
    /// `active` 持续超过 `Pending.delay` 才把 `shown` 置为 true（淡入），`active` 一落就置回。
    func pending(_ active: Bool, shown: Binding<Bool>) -> some View {
        task(id: active) {
            if active { try? await Task.sleep(for: Pending.delay) }
            guard !Task.isCancelled, shown.wrappedValue != active else { return }
            withAnimation(Motion.quick) { shown.wrappedValue = active }
        }
    }

    /// 这一页的数据还没读到：读得慢时在中间淡入一个转圈。
    func loading(_ loading: Bool) -> some View { modifier(Loading(loading: loading)) }
}

private struct Loading: ViewModifier {
    let loading: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if shown { Spinner(.regular).transition(.opacity) }
            }
            .pending(loading, shown: $shown)
    }
}

/// 页头那一行的"正在同步"（Cue 页头与状态行、会话顶栏）：这一页的事实在别的设备上、本机正在和 iCloud 对，页头原来那一句可能已经过时。
/// 字号与颜色跟着那一行，转圈是最小号。
struct SyncingLabel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Spinner(.mini).accessibilityHidden(true)
            Text("正在同步")
        }
        .foregroundStyle(palette.ink3)
        .accessibilityElement(children: .combine)
    }
}
