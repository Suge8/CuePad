#if os(iOS)
import CueStore
import SwiftUI

/// Pi 会话状态的颜色与文字。等你确认是橙色，干活是蓝/紫，出错红色，空闲灰色。
nonisolated extension PiWorkState {
    var label: String {
        switch self {
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool: "工具"
        case .waitingForUser: "等你确认"
        case .settled: "空闲"
        case .error: "出错"
        case .unknown: "未知状态"
        }
    }

    var tint: Color {
        switch self {
        case .thinking: .purple
        case .outputting: .teal
        case .tool: .blue
        case .waitingForUser: .orange
        case .error: .red
        case .settled, .unknown: .gray
        }
    }

    /// 同一项目有多个会话时，状态点显示最需要注意的那个。
    var urgency: Int {
        switch self {
        case .waitingForUser: 4
        case .error: 3
        case .thinking, .outputting, .tool: 2
        case .settled, .unknown: 1
        }
    }
}

nonisolated extension PiSessionState {
    /// "工具 · bash"、"等你确认 · 要覆盖吗？"。
    var summary: String {
        [state.label, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 每个项目最需要注意的会话状态（书架与侧栏的状态点）。
    static func byProject(_ sessions: [PiSessionState]) -> [UUID: PiWorkState] {
        var result: [UUID: PiWorkState] = [:]
        for session in sessions {
            guard let project = session.projectID else { continue }
            if (result[project]?.urgency ?? 0) < session.state.urgency { result[project] = session.state }
        }
        return result
    }
}

/// 状态点：干活时轻微呼吸（减弱动态效果时静止），状态靠颜色与旁边的文字表达。
struct PiDot: View {
    let state: PiWorkState
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            .padding(size * 0.35)
            .background(state.tint.opacity(0.22), in: .circle)
            .opacity(breathing ? 0.45 : 1)
            .animation(breathe ? .easeInOut(duration: 1.1).repeatForever() : nil, value: breathing)
            .onAppear { breathing = breathe }
            .onChange(of: breathe) { _, on in breathing = on }
            .accessibilityHidden(true)
    }

    private var breathe: Bool { state.isWorking && !reduceMotion }
}
#endif
