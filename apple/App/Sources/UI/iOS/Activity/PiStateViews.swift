#if os(iOS)
import CueStore
import SwiftUI

/// Pi 会话状态的颜色与文字。只有要你注意的状态有颜色：等你确认橙、出错红；干活中是中性实心点，空闲浅灰。
nonisolated extension PiWorkState {
    var label: String {
        switch self {
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool: "工具"
        case .waitingForUser: "等你确认"
        case .settled: "空闲"
        case .error: "出错"
        }
    }

    /// 同一项目有多个会话时，状态点显示最需要注意的那个。
    var urgency: Int {
        switch self {
        case .waitingForUser: 4
        case .error: 3
        case .thinking, .outputting, .tool: 2
        case .settled: 1
        }
    }
}

/// 其他版本写入的、本版本不认识的状态：灰色、最低优先。
nonisolated extension Open<PiWorkState> {
    var label: String { known?.label ?? "未知状态" }
    var urgency: Int { known?.urgency ?? 1 }
}

extension PiWorkState {
    func tint(_ palette: Palette) -> Color {
        switch self {
        case .thinking, .outputting, .tool: palette.ink
        case .waitingForUser: palette.attention
        case .error: palette.failure
        case .settled: palette.ink3
        }
    }
}

extension Open<PiWorkState> {
    func tint(_ palette: Palette) -> Color { known?.tint(palette) ?? palette.ink3 }
}

nonisolated extension PiSessionState {
    /// "工具 · bash"、"等你确认 · 要覆盖吗？"。
    var summary: String {
        [state.label, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 每个项目最需要注意的会话状态（书架与侧栏的状态点）。
    static func byProject(_ sessions: [PiSessionState]) -> [UUID: Open<PiWorkState>] {
        var result: [UUID: Open<PiWorkState>] = [:]
        for session in sessions {
            guard let project = session.projectID else { continue }
            if (result[project]?.urgency ?? 0) < session.state.urgency { result[project] = session.state }
        }
        return result
    }
}

/// 状态点：颜色表示状态，旁边总有文字或读屏标签说明；不做循环动画（常驻多处，循环既耗电也分散注意）。
struct PiDot: View {
    let state: Open<PiWorkState>
    var size: CGFloat = 8
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = state.tint(palette)
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .padding(size * 0.35)
            .background(tint.opacity(0.22), in: .circle)
            .animation(Motion.quick, value: state)
            .accessibilityHidden(true)
    }
}
#endif
