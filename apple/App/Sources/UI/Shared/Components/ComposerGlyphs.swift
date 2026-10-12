import SwiftUI

/// 输入框里的圆钮（看得见的 36，点得到的 44）：＋、提交钮、停止钮同一个。
struct CircleGlyph<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 36, height: 36)
            .background(fill, in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}

/// 输入框右下角的提交钮：存下（记成灵感）是打勾，发出（发给 Agent、回复、开新会话）是向上箭头——
/// 两种动作长得不一样，记下不会被看成发出。能按时靛青实心（主动作），按不了（同步不通、正在提交）时淡。
struct SubmitGlyph: View {
    enum Action {
        case save, send
        var symbol: String { self == .save ? "checkmark" : "arrow.up" }
    }

    let action: Action
    let enabled: Bool
    @Environment(\.palette) private var palette

    init(_ action: Action, enabled: Bool) {
        self.action = action
        self.enabled = enabled
    }

    var body: some View {
        CircleGlyph(fill: enabled ? palette.signatureFill : palette.fill) {
            Image(systemName: action.symbol).font(.body.weight(.semibold)).foregroundStyle(enabled ? palette.onSignature : palette.ink3)
        }
        .animation(Motion.quick, value: enabled)
    }
}

/// 输入框右下角的停止钮（Agent 跑一轮时代替提交钮）：墨色实心方块；停止请求已发出、这一轮还没歇下时换成转圈，不能再点。
struct StopGlyph: View {
    let stopping: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        CircleGlyph(fill: stopping ? palette.fill : palette.ink) {
            if stopping {
                Spinner(.small)
            } else {
                Image(systemName: "stop.fill").font(.caption.weight(.bold)).foregroundStyle(palette.paper)
            }
        }
        .animation(Motion.quick, value: stopping)
    }
}
