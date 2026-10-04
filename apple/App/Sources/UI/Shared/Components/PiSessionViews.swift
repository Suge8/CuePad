import CueStore
import SwiftUI

/// Pi 会话状态的颜色与文字。只有要你注意的状态有颜色：等你确认橙、出错红；干活中是中性实心点，空闲浅灰。
nonisolated extension PiWorkState {
    var label: String {
        switch self {
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool: "工具"
        case .delegating: "子代理工作中"
        case .waitingForUser: "等你确认"
        case .settled: "空闲"
        case .error: "出错"
        case .ended: "已结束"
        }
    }

    /// 同一项目有多个会话时，状态点显示最需要注意的那个。
    var urgency: Int {
        switch self {
        case .waitingForUser: 4
        case .error: 3
        case .thinking, .outputting, .tool, .delegating: 2
        case .settled: 1
        case .ended: 0
        }
    }
}

/// 其他版本写入的、本版本不认识的状态：灰色、最低优先。
nonisolated extension Open<PiWorkState> {
    var label: String { known?.label ?? "未知状态" }
    var urgency: Int { known?.urgency ?? 1 }

    /// 项目旁的状态点说的是什么（读屏标签、悬停提示、长按菜单的标题）：只分要你注意的与在忙的。
    var presence: String {
        switch known {
        case .thinking, .outputting, .tool, .delegating: "Pi 正在工作"
        case .waitingForUser: "Pi 等你确认"
        case .error: "Pi 出错"
        case .settled: "Pi 空闲"
        case .ended: "Pi 会话已结束"
        case nil: "Pi 状态未知"
        }
    }
}

extension PiWorkState {
    func tint(_ palette: Palette) -> Color {
        switch self {
        case .thinking, .outputting, .tool, .delegating: palette.ink
        case .waitingForUser: palette.attention
        case .error: palette.failure
        case .settled, .ended: palette.ink3
        }
    }
}

extension Open<PiWorkState> {
    func tint(_ palette: Palette) -> Color { known?.tint(palette) ?? palette.ink3 }
}

nonisolated extension PiSessionState {
    /// 详情是工具命令（等宽显示）。
    var detailIsCode: Bool { state == .known(.tool) }

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

/// 状态点：颜色表示状态；不做循环动画（常驻多处，循环既耗电也分散注意）。旁边有状态文字时（活动页、会话行）
/// 读屏跳过它；`announces` 用在只有一个点的地方（书架、侧栏的项目旁），点自己带读屏标签与悬停提示。
struct PiStateDot: View {
    let state: Open<PiWorkState>
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = state.tint(palette)
        let dot = Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .padding(size * 0.35)
            .background(tint.opacity(0.22), in: .circle)
            .animation(Motion.quick, value: state)
        if announces {
            dot.accessibilityLabel(state.presence).help(state.presence)
        } else {
            dot.accessibilityHidden(true)
        }
    }
}

nonisolated extension PiQuestion {
    /// 只读地显示问题：文案，下面每个选项一行。能作答的界面直接用 `options` 做成按钮。
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}
