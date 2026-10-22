import SwiftUI

/// 全 App 唯一的等待转圈（发送中、送达中、读下一页、正在开…）：与 Agent 状态标同一段弧（`orbit`），交给渲染服务转，App 进程不参与；
/// 不用系统 `ProgressView`，全 App 的转圈是同一个样子、同一个颜色。减弱动态效果时是一段静止的弧。读屏读作"请稍候"，旁边的文字说在等什么。
struct Spinner: View {
    enum Size {
        case mini, small, regular
        var side: CGFloat {
            switch self {
            case .mini: 11
            case .small: 15
            case .regular: 20
            }
        }
    }

    var size = Size.small
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ size: Size = .small) { self.size = size }

    var body: some View {
        Group {
            if reduceMotion {
                let width = size.side * 0.14
                Circle().stroke(palette.track, lineWidth: width)
                    .overlay { Circle().trim(from: 0, to: 0.3).stroke(palette.ink2, style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                    .padding(width / 2)
            } else {
                LoopLayer(kind: .orbit, color: palette.ink2)
            }
        }
        .frame(width: size.side, height: size.side)
        .accessibilityElement()
        .accessibilityLabel("请稍候")
    }
}

/// 省电模式开着（`ProcessInfo.isLowPowerModeEnabled`，随系统的变化通知更新）：读它的常驻动效换成静止的样子，同减弱动态效果。
@Observable final class LowPowerMode {
    static let shared = LowPowerMode()
    private(set) var isOn = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        Task {
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}
