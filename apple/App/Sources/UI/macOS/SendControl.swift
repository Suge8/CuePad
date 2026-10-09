#if os(macOS)
import SwiftUI

/// 提示词的发送钮（⌘↩）+ 选会话：发给本项目的 Agent 会话（`Workspace.agentTarget`），能一按就发时是靛青主钮；
/// 本项目还没有会话或选过的会话已结束时只是选会话的菜单（中性样式）。只在有内容可发时出现（由调用方决定）。
/// 按钮上写"发给 Agent · <会话名>"，过长只截会话名；会话正忙时转为询问马上说还是等它做完再说（`Workspace.send`）。
struct SendControl: View {
    let project: UUID?
    var compact = false
    /// 给了时菜单最上面多一项"新会话"（见 `Workspace.newSessionHandOff`）。
    var newSession: (() -> Void)? = nil
    let send: (AgentTarget) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let target = workspace.agentTarget(for: project)
        let ready = target.map { !workspace.isEnded($0) } ?? false
        Group {
            if let target, ready {
                HStack(spacing: 0) {
                    Button { send(target) } label: {
                        label(dot: workspace.session(target.session).map(workspace.shown), text: "发给 Agent · \(name(target))", shortcut: "⌘↩")
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(workspace.action(for: target))
                    SessionMenu(project: project, newSession: newSession) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .padding(.trailing, compact ? 10 : 14).padding(.leading, 4)
                            .frame(height: compact ? 28 : 44)
                            .contentShape(.rect)
                    }
                }
            } else {
                SessionMenu(project: project, newSession: newSession) {
                    label(dot: target.map { _ in PiShown(state: .known(.ended)) },
                          text: target.map { "\(name($0)) · 已结束" } ?? "交给 Agent…", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
            }
        }
        .font((compact ? Typography.meta : Typography.secondary).weight(.semibold))
        .foregroundStyle(ready ? palette.onSignature : palette.ink)
        .background(ready ? palette.signatureFill : palette.fill, in: .capsule)
        .shadow(color: .black.opacity(palette.dark || compact ? 0 : 0.12), radius: 6, y: 2)
        .fixedSize()
    }

    private func label(dot: PiShown?, text: String, shortcut: String?) -> some View {
        HStack(spacing: 8) {
            if let dot { PiStateDot(shown: dot, size: 5) } else { Image(systemName: "paperplane.fill").accessibilityHidden(true) }
            Text(text).lineLimit(1)
            if let shortcut { Text(shortcut).opacity(0.6) }
        }
        .padding(.leading, compact ? 12 : 16)
        .frame(height: compact ? 28 : 44)
        .contentShape(.rect)
    }

    /// 截断后的会话名。
    private func name(_ target: AgentTarget) -> String {
        let full = workspace.sessionName(target.session), limit = compact ? 8 : 14
        return full.count > limit ? full.prefix(limit - 1) + "…" : full
    }
}

/// 选会话的菜单：在线的 Agent 会话（当前的打勾），可选"新会话"；没有在线会话时留一行怎么开始。
struct SessionMenu<Label: View>: View {
    let project: UUID?
    var newSession: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let current = workspace.agentTarget(for: project)
        Menu {
            if let newSession { Button("新会话", systemImage: "plus", action: newSession) }
            if services.pi.sessions.isEmpty, newSession == nil {
                Button("没有运行中的 Agent 会话 · 在终端运行 pi 开始") {}.disabled(true)
            }
            ForEach(services.pi.sessions) { session in
                Toggle(
                    "\(session.displayName) · \(workspace.shown(session).label)",
                    isOn: Binding(get: { current?.session == session.id }, set: { _ in workspace.sendChoice = AgentTarget(session: session.id) }))
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择 Agent 会话")
        .accessibilityLabel("选择 Agent 会话")
    }
}
#endif
