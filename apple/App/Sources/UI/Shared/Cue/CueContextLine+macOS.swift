#if os(macOS)
import CueStore
import SwiftUI

/// 只读随状态同步来的 `CueState.context`，哪台都看得到值班那台的同一份。比例是已用对换新线（`CueContext.renewAt`）：用满 Cue 下次醒来就开新会话，
/// 之前的经过只剩记忆，这是看它的唯一理由；窗口多大、会话几点起、还差多少 token 都不写。
struct CueContextLine: View {
    let context: CueContext?
    @Environment(\.palette) private var palette

    private var fraction: Double { min(Double(context?.used ?? 0) / Double(CueContext.renewAt), 1) }
    private var percent: String { "\(Int((fraction * 100).rounded()))%" }

    var body: some View {
        let level = UsageLevel(used: fraction)
        HStack(spacing: Spacing.item) {
            Text("上下文").foregroundStyle(palette.ink3)
            MarkedBar(fill: fraction, mark: nil, level: level)
            Text(percent).fontWeight(.semibold).monospacedDigit().foregroundStyle(level == .critical ? palette.failure : palette.ink2)
                .contentTransition(.numericText(value: fraction))
        }
        .font(Typography.meta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上下文")
        .accessibilityValue("已用 \(percent)")
        .animation(Motion.fade, value: context)
    }
}
#endif
