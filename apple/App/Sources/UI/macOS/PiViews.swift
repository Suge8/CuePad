#if os(macOS)
import CuePi
import SwiftUI

// MARK: Pi 状态

extension PiAgentState {
    var label: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool(let name, let running, _): running.count > 1 ? "工具 · \(name) 等 \(running.count) 个" : "工具 · \(name)"
        case .waitingUser: "等你确认"
        case .done(let aborted): aborted ? "已中止" : "完成"
        case .error: "出错"
        }
    }

    /// 此刻在做什么的一句话：工具调用摘要、弹窗标题或出错的人话摘要；旧扩展不带详情时为 nil，界面只显示状态。
    var detail: String? {
        if let summary = errorSummary { return summary.title }
        return fullDetail
    }

    /// 详情的全文（出错时是 Pi 上报的原文），给悬停提示。
    var fullDetail: String? {
        let text: String? = switch self {
        case .tool(_, _, let detail): detail
        case .waitingUser(_, let title): title
        case .error(let message): message
        default: nil
        }
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// 详情是命令或路径（工具调用）时用等宽字。
    var detailIsCode: Bool {
        if case .tool = self { true } else { false }
    }

    /// 状态色只表达含义：运行中是中性的墨，等你确认用注意色，出错用失败色。
    func tint(_ palette: Palette) -> Color {
        switch self {
        case .idle, .done: palette.ink3
        case .thinking, .outputting, .tool: palette.ink2
        case .waitingUser: palette.attention
        case .error: palette.failure
        }
    }

    /// 状态文字的颜色：只有需要处理的才上色。
    func labelColor(_ palette: Palette) -> Color {
        needsAttention ? tint(palette) : palette.ink3
    }

    /// 需要用户过去看一眼。
    var needsAttention: Bool {
        switch self {
        case .waitingUser, .error: true
        default: false
        }
    }
}

struct PiDot: View {
    let state: PiAgentState?
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = state?.tint(palette) ?? palette.ink3.opacity(0.6)
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                if state?.isBusy == true {
                    Circle().stroke(tint.opacity(0.3), lineWidth: 3).scaleEffect(1.6)
                        .opacity(reduceMotion ? 0 : 1)
                }
            }
            .accessibilityLabel(state?.label ?? "已结束")
    }
}

/// 状态详情的一行文字；没有详情时不占位。
struct PiDetail: View {
    let state: PiAgentState
    var size: CGFloat = 12

    var body: some View {
        if state.detail != nil {
            PiActivityLine(detail: state.detail, detailIsCode: state.detailIsCode, font: .system(size: size), full: state.fullDetail)
                .foregroundStyle(.secondary)
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

#endif
