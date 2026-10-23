import SwiftUI

/// 全 App 唯一的等待转圈（发送中、送达中、读下一页、正在开…）：与 Agent 状态标同一段弧（`orbit`），交给渲染服务转，App 进程不参与；
/// 不用系统 `ProgressView`，全 App 的转圈是同一个样子、同一个颜色。不放循环动效时（`LoopsPlay`）是一段静止的弧。读屏读作"请稍候"，旁边的文字说在等什么。
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
    @LoopsPlay private var spins

    init(_ size: Size = .small) { self.size = size }

    var body: some View {
        Group {
            if spins {
                LoopLayer(kind: .orbit, color: palette.ink2)
            } else {
                let width = size.side * 0.14
                Circle().stroke(palette.track, lineWidth: width)
                    .overlay { Circle().trim(from: 0, to: 0.3).stroke(palette.ink2, style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                    .padding(width / 2)
            }
        }
        .frame(width: size.side, height: size.side)
        .accessibilityElement()
        .accessibilityLabel("请稍候")
    }
}

/// 全 App 唯一的"话在路上"（发送钮、气泡旁的记号、会话状态标）：一架纸飞机一趟趟飞过（`LoopLayer.flight`），不放循环动效时（`LoopsPlay`）是
/// 同一架的静止符号（`Icon.onTheWay`，与飞机同大）。`size` 是框的边长，飞机占它的 86%。
struct OnTheWay: View {
    let size: CGFloat
    let color: Color
    @LoopsPlay private var flies

    var body: some View {
        Group {
            if flies {
                LoopLayer(kind: .flight, color: color)
            } else {
                Image(.onTheWay).font(.system(size: size * 0.86, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}
