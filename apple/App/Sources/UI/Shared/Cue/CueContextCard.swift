import CueStore
import SwiftUI

/// Cue 的上下文用量，两端同一个视图（Mac"运行情况"的顶上、手机 Cue 面板里）：只读随状态同步来的 `CueState.context`（`CueWatch.context`），
/// 哪台都看得到值班那台的同一份。第一行"上下文"与已用 / 换新线（`CueContext.renewAt`），一条刻度尺量到窗口（不知道窗口时量到
/// 换新线往后一截），换新线是尺上一道刻线；末行还差多远、窗口多大、这个班次几点起。用到换新线的七成、九成按会话上下文同一口径
/// 加深与转胭脂（`PiContextMeter.level`）。还没跑过一轮时写"还没请求过模型"。上次几点换新在对话里那条换新的分隔上看，这里不写两遍。
struct CueContextCard: View {
    let context: CueContext?
    @Environment(\.palette) private var palette

    private let renewAt = CueContext.renewAt
    /// 已用的大字（Mac 没有动态字体，给固定字号）。
    #if os(macOS)
    private static let number = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    #else
    private static let number = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("上下文").font(Typography.label).foregroundStyle(palette.ink3)
                Spacer(minLength: 8)
                Text(context.map { CueContext.tokens($0.used) } ?? "—")
                    .font(Self.number).foregroundStyle(palette.ink)
                Text("/ \(CueContext.tokens(renewAt))").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            RenewRuler(used: context?.used ?? 0, renewAt: renewAt, window: context?.window)
            Text(facts).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(palette.fill, in: ChatBlock.shape)
        .accessibilityElement(children: .combine)
        .animation(Motion.quick, value: context)
    }

    private var facts: Dotted {
        guard let context else { return "这个班次还没请求过模型" }
        let used = context.used
        let left = used < renewAt
            ? "离换新线还差 \(CueContext.tokens(renewAt - used))" : "过了换新线 \(CueContext.tokens(used - renewAt))，下次醒来先写交接"
        return Dotted(left, context.window.map { "窗口 \(CueContext.tokens($0))" }, "\(Self.since(context.since)) 起")
    }

    /// 班次起点：今天写几点，更早的带上日期。
    private static func since(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month().day().hour().minute())
    }
}

/// 上下文的刻度尺：底是整把尺，铺色到已用，换新线一道刻线、上面标"换新"。
private struct RenewRuler: View {
    let used: Int
    let renewAt: Int
    let window: Int?
    @Environment(\.palette) private var palette

    /// 尺的全长：窗口；不知道窗口时让换新线落在八成处
    private var scale: Double { Double(max(window ?? Int(Double(renewAt) / 0.8), used, renewAt)) }

    private var fill: Color {
        switch PiContextMeter.level(of: Double(used) / Double(renewAt)) {
        case .critical: palette.failure
        case .tight: palette.ink2
        case .roomy: palette.ink3
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let mark = width * Double(renewAt) / scale
            ZStack(alignment: .bottomLeading) {
                Capsule().fill(palette.hair).frame(height: 6)
                Capsule().fill(fill).frame(width: max(6, width * Double(used) / scale), height: 6)
                    .opacity(used > 0 ? 1 : 0)
                Rectangle().fill(palette.ink2).frame(width: 2, height: 12).offset(x: mark - 1, y: 3)
                Text("换新").font(Typography.caption2).foregroundStyle(palette.ink3).fixedSize()
                    .offset(x: mark - 12, y: -12)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("上下文")
        .accessibilityValue("已用 \(CueContext.tokens(used))，换新线 \(CueContext.tokens(renewAt))")
    }
}
