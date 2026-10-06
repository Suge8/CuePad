import CueStore
import SwiftUI

/// Pi 会话状态的颜色与文字：只有要你注意的有颜色（等你确认橙、出错红）；工作中是墨色，空闲与已结束是灰，靠形状分开。
nonisolated extension PiWorkState {
    var label: String {
        switch self {
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool: "运行工具"
        case .delegating: "子代理工作中"
        case .waitingForUser: "等你确认"
        case .settled: "空闲"
        case .error: "出错"
        case .ended: "已结束"
        }
    }

    /// 会话列表的先后：等你确认 → 出错 → 工作中 → 空闲 → 已结束。
    var listRank: Int {
        switch self {
        case .waitingForUser: 0
        case .error: 1
        case .thinking, .outputting, .tool, .delegating: 2
        case .settled: 3
        case .ended: 4
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

/// 子代理的粗状态借会话状态的图标、颜色与文字（工作中墨色圈点、等你确认橙、空闲灰勾、出错红叹号）。
nonisolated extension PiSubagentState {
    var workState: Open<PiWorkState> {
        switch activity.known {
        case .working: .known(.thinking)
        case .waitingForUser: .known(.waitingForUser)
        case .idle: .known(.settled)
        case .error: .known(.error)
        case nil: .unknown(activity.rawValue)
        }
    }

    var activityLabel: String { activity.known == .working ? "工作中" : workState.label }
}

/// 其他版本写入的、本版本不认识的状态：灰色、最低优先。
nonisolated extension Open<PiWorkState> {
    var label: String { known?.label ?? "未知状态" }
    var urgency: Int { known?.urgency ?? 1 }
    var listRank: Int { known?.listRank ?? 3 }

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
        case .settled: palette.ink3
        case .ended: palette.ink3.opacity(0.6)
        }
    }

    /// 状态标的形状，与颜色一起表达状态（色弱也分得出）：等你确认问号、出错叹号、工作中圈里一个实心点、空闲勾、已结束空心圈。
    var symbol: String {
        switch self {
        case .waitingForUser: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .thinking, .outputting, .tool, .delegating: "smallcircle.filled.circle"
        case .settled: "checkmark.circle"
        case .ended: "circle"
        }
    }
}

extension Open<PiWorkState> {
    func tint(_ palette: Palette) -> Color { known?.tint(palette) ?? palette.ink3 }
}

nonisolated extension PiSessionState {
    /// 会话列表的顺序（Agent 页、Mac 侧栏）：要你注意的在前，同一档保持原来的先后（最近进入当前状态的在前）。
    static func inListOrder(_ sessions: [PiSessionState]) -> [PiSessionState] {
        sessions.enumerated()
            .sorted { ($0.element.state.listRank, $0.offset) < ($1.element.state.listRank, $1.offset) }
            .map(\.element)
    }

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

/// 会话状态标（全 App 只此一份：Agent 页、近况、书架、侧栏、Mac 侧栏与菜单栏）：颜色 + 形状表达状态，
/// 等你确认橙色问号、出错红色叹号、工作中墨色圈点、空闲灰色勾、已结束更淡的空心圈；不做循环动画（常驻多处，
/// 循环既耗电也分散注意）。`size` 是点的直径，符号按它放大到同样的视觉分量。
/// 旁边有状态文字时读屏跳过它；`announces` 用在只有一个标的地方（书架、侧栏的项目旁），标自己带读屏标签与悬停提示。
struct PiStateDot: View {
    let state: Open<PiWorkState>
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    /// 跟着旁边的字随辅助字号放大
    @ScaledMetric private var scale: CGFloat = 1

    private var box: CGFloat { size * 1.8 * scale }

    var body: some View {
        let mark = Image(systemName: state.known?.symbol ?? "circle.dashed").font(.system(size: box, weight: .semibold))
            .foregroundStyle(state.tint(palette))
            .frame(width: box, height: box)
            .animation(Motion.quick, value: state)
        if announces {
            mark.accessibilityLabel(state.presence).help(state.presence)
        } else {
            mark.accessibilityHidden(true)
        }
    }
}

nonisolated extension PiQuestion {
    /// 只读地显示问题（只能在 Pi 里答的、或列表里的预览）：文案，下面每个选项一行。能作答的问题卡用 `options` 做成按钮。
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}

nonisolated extension PiAnswerValue {
    /// 答了什么，一句话："覆盖"、"是"。
    var label: String {
        switch self {
        case .option(let option): option
        case .confirmed(let confirmed): confirmed ? "是" : "否"
        case .text(let text): text
        }
    }
}
