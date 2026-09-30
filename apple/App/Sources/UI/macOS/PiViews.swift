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

    /// 此刻在做什么的一句话：工具调用摘要、弹窗标题或错误信息；旧扩展不带详情时为 nil，界面只显示状态。
    var detail: String? {
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

    var tint: Color {
        switch self {
        case .idle, .done: .secondary
        case .thinking, .outputting: .purple
        case .tool: .blue
        case .waitingUser: .orange
        case .error: .red
        }
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

    var body: some View {
        Circle()
            .fill(state?.tint ?? .secondary.opacity(0.5))
            .frame(width: size, height: size)
            .overlay {
                if state?.isBusy == true {
                    Circle().stroke((state?.tint ?? .clear).opacity(0.35), lineWidth: 3).scaleEffect(1.6)
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
        if let detail = state.detail {
            Text(detail)
                .font(.system(size: size, design: state.detailIsCode ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
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
